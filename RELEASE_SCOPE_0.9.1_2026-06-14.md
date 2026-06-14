# pgmnemo v0.9.1 — Release Scope Ratification

**Date:** 2026-06-14  
**Ratified by:** Chief Architect (CA)  
**Working group:** CA, PI (77), RS (85), mem-principal (97)  
**Investor gate:** NONE — WG decides

---

## 1. Issue verification & closure

### #21 — R4: `recall_lessons()` diagnostic score columns

**Verdict: CLOSED (done in v0.4.1, present in v0.9.0)**

Evidence:
- `extension/pgmnemo--0.9.0.sql` lines 5117–5134: public `RETURNS TABLE` of the final
  `recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ)` overload includes:
  ```
  vec_score     DOUBLE PRECISION,   -- line 5130
  bm25_score    DOUBLE PRECISION,   -- line 5131
  rrf_score     DOUBLE PRECISION,   -- line 5132
  ```
- CHANGELOG `[0.4.1]` (line 1096–1101): "Appended `vec_score`, `bm25_score`, `rrf_score`. Issue #21."
- All three columns present across every intermediate version (0.4.1 → 0.9.0).

**Action:** Close issue #21 with comment: "Verified in v0.9.0 `extension/pgmnemo--0.9.0.sql`
L5130–5132. All three diagnostic score columns present in public RETURNS TABLE."

---

### #25 — R8: `evict_expired_lessons()` per-row `expires_at`

**Verdict: CLOSED (done in v0.1.4, present in v0.9.0)**

Evidence:
- `extension/pgmnemo--0.9.0.sql` lines 695–699:
  ```sql
  DELETE FROM pgmnemo.agent_lesson
  WHERE expires_at IS NOT NULL
    AND expires_at < NOW()
  ```
  Deletion predicate is per-row (`expires_at` is a column on `agent_lesson`,
  defined at line 135). Each row's own TTL is honored.
- `agent_lesson.expires_at` indexed at lines 217–219 (partial index WHERE NOT NULL).

Note: R8 also referenced "project-scoped TTL eviction" (CHANGELOG line 1187). That sub-feature
(filtering evictions by `project_id`) was never shipped — but it is NOT what issue #25 tracks.
The per-row `expires_at` semantics are fully present.

**Action:** Close issue #25 with comment: "Per-row `expires_at` honored since v0.1.4.
Verified in v0.9.0 `extension/pgmnemo--0.9.0.sql` L695–699. Project-scoped eviction
(R8 sub-item) was explicitly deferred in CHANGELOG [0.4.1] — if desired, open a
separate issue."

---

### #31 — Split: done parts vs. remaining

**Parts shipped (close in #31 comment):**
- **Project-scoped recall** — `project_id_filter` on `recall_hybrid()` since v0.4.0;
  `project_id_filter` on `navigate_locate()` added in v0.9.0 (#1b). Done.
- **Tagged ingest** — `metadata JSONB` on `ingest()` + JSONB predicate pushdown in recall
  since v0.5.0+. Done.

**Part NOT done — open new narrow issue:**
- **Versioned skill items** — no `skill_version` or equivalent column on `agent_lesson`;
  no query-by-version filter on any recall path.
  Proposed new issue title: "feat: versioned skill items — add `skill_id`/`skill_version`
  columns to `agent_lesson` with recall filter parity"

**Action:** Add closing comment to #31 documenting shipped parts; open new narrow issue
for versioned skill items only. Do NOT add versioned skill items to 0.9.1 scope
(no benchmarked need established yet).

---

## 2. Removal audit — three dead stored procedures

### Candidates

| SP | Signature | Introduced | Last touched in migration |
|---|---|---|---|
| `traverse_causal_chain` | `(BIGINT, INT, TEXT[], BOOLEAN, TEXT)` | v0.2.1 | 0.4.1→0.5.0 DROP of 4-arg overload |
| `traverse_temporal_window` | `(BIGINT, INTERVAL, BOOLEAN, TEXT, INT, INT)` | v0.2.0 | 0.8.1→0.8.2 (F1 fix) |
| `recall_lessons_pooled` | `(vector, INT, INT)` | v0.1.2 | 0.6.x (6-arg recall delegation) |

### Caller audit

**Agency app (`/workspace/apps/v3-next/`, `/workspace/`):**
- `.py` / `.ts` / `.js` grep: zero real calls to any of the three SPs.
- `curate_mem_edges.py` line 14: doc-comment reference to `traverse_temporal_window()` only —
  not a function call.

**pgmnemo_mcp (`/external-repos/pgmnemo/pgmnemo_mcp/`):**
- Zero references to any of the three SPs.

**pg_regress fixtures (`tests/sql/test_v071.sql`, `tests/sql/test_v080.sql`):**
- Zero references. No fixture update required.

**Historical migration SQL in workspace Docker dir:**
- `docker/postgres/pgmnemo-extension/` files contain function *definitions* in old migrations,
  not *callers*. Irrelevant to runtime caller audit.

### Decision: DROP NOW (pre-1.0 semver)

Rationale:
1. Zero verified callers in Agency or MCP.
2. Pre-1.0 semver: no API stability commitment. CHANGELOG [v1.0] criteria require 2 consecutive
   non-breaking releases; carrying dead SPs delays that window.
3. Deprecation-via-COMMENT path requires carrying the dead code to 1.0 then removing it —
   that's two breaking-change cycles for zero benefit.
4. `traverse_temporal_window` had a doc-only reference in Agency app code but zero runtime calls.

**No pg_regress fixture changes required** — active regress tests contain zero references.

**Migration file authored:** `extension/pgmnemo--0.9.0--0.9.1.sql`
(see §4 for DROP statements + navigate_locate fix)

---

## 3. v0.9.1 Build scope — RATIFIED

### P0 — navigate_expand traversal fix (owned by task 9017 / mem-principal 97)

**Do not duplicate.** Task 9017 owns:
- Fix `navigate_expand` graph traversal bug (incorrect neighbor expansion)
- nav-efficiency benchmark gate

0.9.1 migration file reserves a clearly-marked section for task 9017's implementation.
CA coordination point: task 9017 appends its `navigate_expand` replacement to
`extension/pgmnemo--0.9.0--0.9.1.sql` and the corresponding full-version file.

### P1 — navigate_locate O(n) → O(k log n) topic tsvector fix

**IN SCOPE. Cheap: 2-line substitution.**

Root cause: `navigate_locate` raw_candidates CTE (0.9.0 lines 4136–4140) recomputes
`to_tsvector('english', COALESCE(al.topic, ''))` inline on every row, bypassing the stored
generated column `topic_tsv` (GIN-indexed at line 181–182 of 0.9.0.sql).

Fix (exact-semantics-preserving):
```sql
-- BEFORE (O(n) tsvector recompute on every row):
OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery
...
ts_rank_cd(setweight(to_tsvector('english', COALESCE(al.topic, '')), 'A') || al.lesson_tsv, ...)

-- AFTER (uses stored generated columns, GIN-indexable):
OR al.topic_tsv @@ _tsquery
...
ts_rank_cd(setweight(al.topic_tsv, 'A') || al.lesson_tsv, ...)
```

`topic_tsv TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', coalesce(topic, ''))) STORED`
(schema line 108). `pgmnemo_agent_lesson_topic_tsv_idx` GIN index (line 181).

No signature change. No behavioral change (semantically identical). No benchmark gate required
(it's a pure index-access correction, not a scoring change).

Implementer note: update both `raw_candidates` WHERE clause and BM25 rank expression.

### P1 — Dead SP removal (authored in migration skeleton)

Remove three zero-caller SPs:
- `pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN, TEXT)`
- `pgmnemo.traverse_temporal_window(BIGINT, INTERVAL, BOOLEAN, TEXT, INT, INT)`
- `pgmnemo.recall_lessons_pooled(vector, INT, INT)`

DROP statements authored in `extension/pgmnemo--0.9.0--0.9.1.sql`.

### OUT OF SCOPE for 0.9.1

- Versioned skill items (`skill_id`/`skill_version`) — new issue required first
- Project-scoped TTL eviction — no issue, no design
- Any new schema columns not in the current migration skeleton
- Speculative features without caller demand or bench gate

---

## 4. RATIFIED SCOPE SUMMARY

| Item | Priority | Owner | Status |
|---|---|---|---|
| navigate_expand traversal fix | P0 | task 9017 / mem-principal 97 | IN SCOPE — do not duplicate |
| nav-efficiency benchmark | P0 | task 9017 / mem-principal 97 | IN SCOPE — gate for P0 |
| navigate_locate topic_tsv O(n) fix | P1 | SD (next available) | IN SCOPE — cheap, 2-line |
| DROP traverse_causal_chain | P1 | SD (migration skeleton authored) | IN SCOPE |
| DROP traverse_temporal_window | P1 | SD (migration skeleton authored) | IN SCOPE |
| DROP recall_lessons_pooled | P1 | SD (migration skeleton authored) | IN SCOPE |
| Close #21 | admin | WG | READY TO CLOSE |
| Close #25 | admin | WG | READY TO CLOSE |
| Split #31 + open versioned-skill issue | admin | WG | READY TO EXECUTE |

**Blocking condition for RELEASE:** P0 benchmark gate (task 9017) must pass before tagging v0.9.1.
P1 items (drops + navigate_locate fix) may be implemented in parallel and do not require a
separate benchmark gate.

**Breaking changes in 0.9.1:**
- `traverse_causal_chain`, `traverse_temporal_window`, `recall_lessons_pooled` removed.
  Pre-1.0; callers verified to be zero. CHANGELOG must document removal with upgrade note.

---

*Ratified: 2026-06-14 by Chief Architect*
