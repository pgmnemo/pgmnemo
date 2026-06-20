# Changelog

All notable changes to `pgmnemo` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

## Breaking changes quick-scan

| Version | Breaking change | Migration |
|---|---|---|
| **0.9.1** | `navigate_expand` 4-arg overload dropped (5th param `relation_types TEXT[]` added) | Positional callers unaffected (DEFAULT NULL); explicit overload refs must update |
| **0.9.0** | `navigate_locate` budget counter fixed — ~5× more IDs returned per equivalent budget | Callers with `token_budget_chars` need proportional adjustment; see §Breaking changes in [0.9.0] |
| **0.5.0** | 4-arg `traverse_causal_chain` removed | Use 2-arg form + `WHERE` clause |
| **0.5.0** | `mem_edge` columns renamed: `lesson_a_id` → `source_id`, `lesson_b_id` → `target_id` | Use `pgmnemo.add_edge()` to avoid direct column references; see [docs/MIGRATION.md](docs/MIGRATION.md) |

---

## [0.9.8] — 2026-06-20

### Theme

**Tiered-memory dispatch + `recall_fast()` + MCP recall fast-by-default.**
Adds per-content-type access-path routing (`navigate_locate_dispatch`), typed
dereference (`navigate_expand_typed`), selective-embedding backfill
(`apply_selective_embedding_policy`), and a new `recall_fast()` function for
pure HNSW vector recall at O(k log n). MCP `pgmnemo.recall` now routes to
`recall_fast()` by default; `deep=true` opts into `recall_hybrid()` for full
6-signal RRF fusion. Closes #81: `role_filter` / `project_id_filter` /
`exclude_dag_id` confirmed present in the published wheel (wired in v0.9.7 /
cdc1524b) and covered by a new introspection test.

### Added

- **`pgmnemo.recall_fast(query_embedding, k, role_filter, project_id_filter, exclude_dag_id)`**
  Pure HNSW vector recall — `ORDER BY embedding <=> query LIMIT k`.
  No BM25, no graph BFS, no RRF, no recency weighting. score = cosine similarity.
  Return shape: 12-column (identical to `recall_lessons()` — MCP-compatible).
  Respects `include_unverified`, `ef_search`, `track_recall_recency` GUCs.
  Same filter surface as `recall_hybrid`: `role_filter`, `project_id_filter`,
  `exclude_dag_id`. Use when latency matters more than BM25/graph recall depth.

- **`pgmnemo.navigate_locate_dispatch(query_embedding, query_text, token_budget_chars,
  jsonb_filter, project_id_filter, content_type_dispatch)`**
  Routes each query to the cheapest adequate index per `content_type_dispatch`:
  `'entity'` → GIN BM25 on `lesson_tsv`; `'temporal'` → btree on `t_valid_from`;
  `'relation'` → `mem_edge` BFS from BM25 seed; `NULL` → existing `navigate_locate`.
  Return schema identical to `navigate_locate`.

- **`pgmnemo.navigate_expand_typed(ids, expand_fields, graph_depth, weight_threshold,
  content_type_hint)`**
  Content-type-aware typed dereference:
  `'entity'` → metadata JSONB (`canonical_name`, `entity_type`) + connected lessons;
  `'lesson'` / `NULL` → full `lesson_text` (same as `navigate_expand`);
  `'relation'` → `mem_edge` neighbours only.

- **`pgmnemo.apply_selective_embedding_policy(p_dry_run)`**
  Sets `embedding = NULL` for non-semantic content types (`entity`, `fact`,
  `relation`, `temporal`) to reduce HNSW index noise.
  `p_dry_run = TRUE` (default) → preview only; `FALSE` → executes update.

- **New indexes:**
  `ix_pgmnemo_lesson_tsv_entity` (GIN on `lesson_tsv WHERE content_type='entity'`);
  `ix_pgmnemo_content_type_active` (btree on `content_type WHERE is_active`);
  `ix_pgmnemo_temporal_content_type` (btree on `t_valid_from WHERE content_type='temporal'`).

### Changed

- **`pgmnemo.recall` MCP tool (pgmnemo-mcp v0.9.8):**
  Default path changed from `recall_lessons()` → **`recall_fast()`**
  (pure HNSW, lower latency).
  New `deep: bool = False` parameter: when `True`, calls `recall_hybrid()`
  for full vector + BM25 + graph proximity + recency + confidence + provenance fusion.
  `role_filter`, `project_id_filter`, `exclude_dag_id` present in both paths.

- **`pgmnemo.get_params` MCP tool:** version string updated to `"0.9.8"`.

### Extension

Schema additions only — no existing function signatures changed. Upgrade is
non-breaking for all existing callers.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.9.8';
```

MCP server: `pip install --upgrade pgmnemo-mcp==0.9.8`.

### Closes

- **#81** — `role_filter` / `project_id_filter` / `exclude_dag_id` in published
  MCP wheel confirmed and covered by `test_recall_exposes_filter_params` in
  `tests/test_mcp_smoke.py`. These were wired in v0.9.7 (commit cdc1524b).

---

## [0.9.7] — 2026-06-20

### Theme

**MCP params exposure + smoke-test validation.**
Adds a new `pgmnemo.get_params` MCP tool that exposes current server configuration
(DATABASE_URL with masked password, embedding server, embedding model, embedding
dimension, MCP port) so AI clients can verify their connection without accessing
environment variables directly. Companion smoke tests validate all three MCP tools are
registered and functional.

### Added

- **`pgmnemo.get_params` MCP tool** in `pgmnemo_mcp`. Returns `database_url`
  (password masked as `***`), `embedding_server`, `embedding_model`,
  `embedding_dim`, `mcp_port`, and `version`. Allows MCP clients to verify server
  configuration without shell access.
- **`tests/test_mcp_smoke.py`** — 7-test smoke suite covering package import,
  `__version__` assertion, tool registration (ingest / recall / get_params), unit-level
  DB call verification for ingest and recall, and `get_params` password masking.
- **`tests/conftest.py`** — shared pytest fixtures for smoke test suite.

### Changed

- **`pgmnemo_mcp/__init__.py`**: exports `get_params` alongside `ingest`,
  `recall`, `mcp`, `main`. `__version__` bumped to `0.9.7`.
- **`pgmnemo_mcp/pyproject.toml`**: version `0.9.7`; build system updated from
  hatchling to setuptools for compatibility.
- **`pgmnemo_mcp/tests/test_server.py`**: arg-index assertions updated to account for
  the embedding vector at position 5 (commit\_sha → 6, artifact\_hash → 7, metadata → 8
  for ingest; query\_vec → 0, top\_k → 1, query\_text → 2 for recall).

### Extension

No schema changes in v0.9.7. Extension `default_version` updated to `0.9.7`; flat
install file `pgmnemo--0.9.7.sql` and delta `pgmnemo--0.9.6--0.9.7.sql` added
(no-op delta — schema unchanged from 0.9.6).

### Upgrade



No schema changes — this upgrade is a no-op. MCP server: `pip install --upgrade pgmnemo-mcp==0.9.7`.

---

## [0.9.6] — 2026-06-19

### Theme

**R11/R12/R13 — Versioned skill items, DAG-scoped recall, migration ingest log.**
Three community requirements addressed in one schema release: content-type classification
for non-free-form lessons (`item_kind`), version tracking for evolving skills
(`version_n`, `patch_count`), workflow-origin tagging and exclusion (`source_dag_id`,
`exclude_dag_id`), and a migration helper table (`memory_ingest_log`) for operators
moving from legacy memory schemas.

### Added

- **`item_kind TEXT NOT NULL DEFAULT 'note'`** on `pgmnemo.agent_lesson`.
  CHECK constraint: `('note','skill_md','template','script','reference','config','spec')`.
  Classifies lessons by content type; `'note'` is the default for free-form lessons.
- **`version_n INT NOT NULL DEFAULT 1`** on `pgmnemo.agent_lesson`.
  Monotonically increasing version counter. Increment when `lesson_text` is substantially
  revised (e.g. after a major update to a `skill_md` document).
- **`patch_count INT NOT NULL DEFAULT 0`** on `pgmnemo.agent_lesson`.
  Minor patch edit counter. Reset to 0 on each `version_n` increment.
- **`source_dag_id TEXT NULL`** on `pgmnemo.agent_lesson`.
  Opaque identifier for the workflow/pipeline run that produced the lesson.
  NULL = unknown origin (manually ingested). Sparse index
  `ix_pgmnemo_agent_lesson_source_dag_id` covers non-NULL rows.
- **`exclude_dag_id TEXT DEFAULT NULL`** parameter on `recall_hybrid()` and
  `recall_lessons()`. When set, suppresses lessons whose `source_dag_id` matches the
  given value (`IS DISTINCT FROM` semantics: `NULL source_dag_id` rows always pass).
  Allows a workflow to exclude its own output from recall during the same run.
- **`pgmnemo.memory_ingest_log`** table. Tracks migration batches from legacy memory
  tables into `pgmnemo.agent_lesson`. Columns: `id BIGSERIAL PK`, `source_origin TEXT`,
  `min_id BIGINT`, `max_id BIGINT`, `ingested_at TIMESTAMPTZ DEFAULT NOW()`,
  `retired_at TIMESTAMPTZ NULL`. Operators drop it once the cutover window closes.
- **`extension/sql/versioned_items.sql`** — 5-topic pg_regress test file covering
  column defaults, CHECK enforcement, sparse index, `memory_ingest_log` CRUD, and
  `exclude_dag_id` filter semantics.

### Changed

- **`recall_hybrid()`**: old 8-arg overload dropped; new 9-arg form adds `exclude_dag_id TEXT DEFAULT NULL`.
  Positional callers unaffected (DEFAULT NULL).
- **`recall_lessons()`**: old 6-arg overload dropped; new 7-arg form adds `exclude_dag_id TEXT DEFAULT NULL`.
  Positional callers unaffected (DEFAULT NULL).
- **`docs/SQL_REFERENCE.md`**: `agent_lesson` column table updated with four new columns;
  new `§1.1 pgmnemo.memory_ingest_log` table entry; `recall_hybrid()` and `recall_lessons()`
  signatures updated with `exclude_dag_id` parameter.
- **`docs/MIGRATION.md`**: new section "Legacy table migration via `memory_ingest_log`"
  with a worked example using `INSERT INTO pgmnemo.agent_lesson ... SELECT ...`.

### Breaking changes

`recall_hybrid()` and `recall_lessons()` drop their old fixed-arity overloads and
replace them with new overloads that add `exclude_dag_id TEXT DEFAULT NULL` as the
last parameter. **Positional callers are unaffected** — the new parameter defaults to
NULL. Callers that hold explicit `GRANT EXECUTE` on the old fixed-arity type signatures
(`vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT` and
`vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ`) must re-apply grants to the new signatures.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.9.6';
```

Adds four columns to `pgmnemo.agent_lesson`, one sparse index, and one new table.
Non-destructive; all existing rows receive default values. Estimated duration: <1 s on
any corpus size (no table rewrite).

---

## [0.9.5] — 2026-06-19

### Theme

**E — Recall-recency signals + `mark_stale()`.** Corpus of 6,584 lessons with
92 % never recalled could not be curated by actual use because `last_recalled_at`
didn't exist. This release adds the column, stamps it on every recall path, and
provides a safe, guarded curation primitive.

### Added

- **`last_recalled_at TIMESTAMPTZ DEFAULT NULL`** on `pgmnemo.agent_lesson`.
  Stamped automatically by `recall_hybrid()`, `recall_lessons()`,
  `navigate_locate()`, and `navigate_expand()`. NULL = never recalled since
  v0.9.5 column addition.
- **`recall_count BIGINT NOT NULL DEFAULT 0`** on `pgmnemo.agent_lesson`.
  Incremented once per recall-function call that returns the lesson. Monotonically
  increasing; never decremented.
- **`ix_pgmnemo_lesson_recall_recency` partial index** on `(last_recalled_at ASC
  NULLS FIRST, created_at ASC) WHERE is_active` — supports efficient stale-lesson
  scans.
- **GUC `pgmnemo.track_recall_recency`** (BOOLEAN, default `on`). When set to
  `off`, no stamping occurs and all four recall functions behave byte-identically
  to v0.9.4. Documented in `SQL_REFERENCE.md §3.1`.
- **`pgmnemo.mark_stale()`** — usage-based corpus curation primitive. Identifies
  and optionally deprecates lessons unused for `p_unused_days` (default 45 days).
  Safeguards prevent touching high-confidence (`>= 0.6`), high-importance (`= 5`),
  or provenance-bearing lessons. `p_dry_run=TRUE` (default) is read-only and safe
  to run anytime. `p_cap` (default 500) refuses to deprecate without explicit
  acknowledgement if candidates exceed the cap.
- **`extension/sql/recall_recency.sql`** — 9 pg_regress tests covering stamping,
  GUC control, dry-run, safeguards, and cap guard.

### Changed

- **`recall_hybrid()`**, **`recall_lessons()`**, **`navigate_locate()`**,
  **`navigate_expand()`**: changed from `STABLE` → `VOLATILE` (required for the
  UPDATE side-effect in the data-modifying CTE stamp). No scoring change; existing
  query plans remain valid.
- **`docs/SQL_REFERENCE.md`**: new §3.1 row for `pgmnemo.track_recall_recency`;
  §3.6 entry for v0.9.5 new GUC. New `mark_stale()` entry in §2.
- **`docs/USAGE.md`**: new section "Usage-based curation — `mark_stale()`".

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.9.5';
```

Adds two columns to `pgmnemo.agent_lesson` and creates one partial index.
Non-destructive and backward-compatible. All recall function signatures unchanged.

---

## [0.9.4] — 2026-06-19

### Theme

**Documentation-only release.** No SQL changes. Covers three GUCs shipped in
v0.9.2–v0.9.3 that were missing from `SQL_REFERENCE` and `USAGE`:
`confidence_boost_weight`, `reinforce_success_delta`, `reinforce_fail_delta`.

### Changed

- **`docs/SQL_REFERENCE.md`**: added `confidence_boost_weight` to §3.1 Recall scoring GUCs;
  new §3.3 Outcome-learning GUCs covering `reinforce_success_delta` and `reinforce_fail_delta`;
  §3.6 default-change history updated with v0.9.2–v0.9.3 entries.
- **`docs/USAGE.md`**: `reinforce()` section updated to reflect new default deltas
  (+0.02/−0.12); GUC override example added.
- **`CHANGELOG.md`**: `[0.9.2]` entry annotated — no separate git tag, shipped as part of v0.9.3.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.9.4';
```

No-op — schema unchanged. Safe to run at any time.

---

## [0.9.3] — 2026-06-17

### Theme

**D1 — Base-rate-adjusted `reinforce()` deltas, GUC-configurable.** The shipped
deltas (+0.10/−0.15) caused confidence to saturate at the ceiling under typical
success rates, destroying discriminability. Base-rate-adjusted defaults
(+0.02/−0.12) restore discriminability and show consistent positive correlation
with actual outcome.

### Added

- **Base-rate-adjusted `reinforce()` deltas** (D1): default success delta
  `+0.10` → `+0.02`; failure delta `−0.15` → `−0.12`. Both scalar
  `reinforce(BIGINT, TEXT)` and batch `reinforce(BIGINT[], TEXT)` forms updated.

- **`reinforce()` GUC-configurable deltas**:
  - `pgmnemo.reinforce_success_delta` — DOUBLE PRECISION, default `0.02`,
    clamped `[0.001, 0.5]`. Applied as `confidence += delta` on success.
  - `pgmnemo.reinforce_fail_delta` — DOUBLE PRECISION, default `0.12`,
    clamped `[0.001, 0.5]`. Applied as `confidence -= delta` on failure.
  Override per-session: `SET pgmnemo.reinforce_success_delta = '0.05';`
  Batch form reads GUCs once before the loop for consistency across IDs.

- **Regression test** (`reinforce_delta_guc`): 8 assertions — default success
  delta, default failure delta, GUC override success, GUC override failure,
  clamp prevents overflow, batch form respects GUC, post-RESET defaults restored.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.9.3';
```

New defaults apply immediately. Override per-session or at DB/role level if
your workload has a different base success rate.

---

## [0.9.2] — 2026-06-17 *(no separate tag — shipped as part of v0.9.3)*

### Theme

**I1 — Flag-gated confidence-weighted recall ranking.** `reinforce()` updates
confidence, but its contribution to the `recall_hybrid` final score was
~0.000431 — operationally inert (~3 RRF positions max). Outcome-learning was
marketing, not engineering. This release adds an additive, zero-centered
confidence boost behind a GUC flag: `score += w × (confidence − 0.5)`.

### Added

- **Confidence boost GUC** (`pgmnemo.confidence_boost_weight`): DOUBLE
  PRECISION, default `0.0` (OFF — byte-identical to 0.9.1), clamped
  `[0.0, 0.01]`. Recommended activation value: `0.003`.
  At `w=0.003`, a high-vs-low confidence delta ≈ 0.0024 ≈ 8–15 RRF positions.
  Cold-start (`confidence=0.5`) gets zero boost/penalty.

- **`recall_hybrid()` I1 term**: additive `+ w × (confidence − 0.5)` in the
  `final` CTE, after the aux-scale block and before the graph-proximity
  multiplier. Strong tie-breaker, not driver.

- **Regression test** (`confidence_boost_guc`): 5 tests — GUC default, GUC ON
  ranking, cold-start invariance, flag-OFF regression, spread amplification.

### Activation gate

Do NOT flip default to ON. Pending: positive A/B validation.
Activate per-session: `SET pgmnemo.confidence_boost_weight = '0.003';`

---

## [0.9.1] — 2026-06-14

### Theme

**P0 graph traversal fix.** `navigate_expand` and `navigate_locate` graph
walks filtered `edge_kind IN ('causal','temporal')`, making entity and
semantic edges invisible. Production edges written via `backfill_mem_edge.py`
all had `edge_kind='semantic'` (unmapped `CO_TEMPORAL` relation_type defaults
to semantic in `add_edge`'s CASE). Result: graph expansion step-2 returned
zero neighbors for 100% of production edges.

### Fixed

- **B1 — `navigate_expand` edge filter** (#graph, #P0): replaced
  `me.edge_kind IN ('causal','temporal')` with
  `me.relation_type = ANY(relation_types)`. `relation_type` is the actual
  typed discriminator; `edge_kind` is a coarse 4-value category that silently
  miscategorized production edges. New parameter: `relation_types TEXT[]
  DEFAULT NULL` — NULL traverses ALL active edges (no type filter).

- **B2 — `valid_until` sentinel mismatch** (#graph): edges could carry
  `valid_until = 'infinity'::TIMESTAMPTZ` (following `agent_lesson.t_valid_to`
  convention) instead of NULL. Old filter `valid_until IS NULL` excluded them.
  Fix: `(valid_until IS NULL OR valid_until = 'infinity'::TIMESTAMPTZ)`.

- **B3 — Forward-only BFS** (#graph): graph expansion only followed
  `me.source_id = node → me.target_id`. Backward relations (e.g. discovering
  a cause from its effect) were invisible. Fix: bidirectional join on
  `(source_id = node OR target_id = node)` with CASE to select the opposite
  endpoint.

- **B4 — Default weight threshold 0.7 → 0.5** (#graph): navigation should be
  permissive — the agent decides which connections to follow. 0.7 was too
  aggressive for sparse graphs.

- **`navigate_locate` graph_walk** (#graph): same B1+B2+B3 fixes applied to
  the proximity-scoring BFS in `navigate_locate`. All `relation_type`s now
  contribute to proximity boost.

- **P1-D — `navigate_locate` topic BM25 seq-scan** (#performance): replaced
  inline `to_tsvector('english', COALESCE(topic,''))` with stored generated
  column `topic_tsv` (GIN-indexed). Eliminates O(n) recompute per row in
  `raw_candidates`.

### Breaking changes

- `navigate_expand` signature changed from 4-arg
  `(BIGINT[], TEXT[], INT, FLOAT)` to 5-arg
  `(BIGINT[], TEXT[], INT, FLOAT, TEXT[])`. Old 4-arg overload is dropped in
  the migration (`DROP FUNCTION IF EXISTS`). Callers using only positional
  args 1–4 are unaffected (5th arg defaults to NULL). Callers storing the
  function signature explicitly must update.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.9.1';
```

---

## [0.9.0] — 2026-06-10

### Theme

**Token-economy correctness + recall performance + schema extension.**
Five patches: budget counter fix, project_id scoping for navigate_locate,
NULL-embedding ghost-exclusion fix, content_type/blob_ref/doc_ref columns,
and recall_hybrid O(n) rewrite to bounded CTEs.

### Fixed

- **#1 — `navigate_locate` budget counter** (#budget, #token-economy):
  `token_budget_chars` previously counted full `length(lesson_text)` but
  delivered only `left(lesson_text, 50)` as preview. Budget filled ~5x too
  fast. Fix: `LEAST(length(lesson_text), 50)` — counter now matches delivered
  payload. **Behavioral change:** callers with `token_budget_chars=2000` will
  receive ~40 rows (previously ~8). The budget now counts preview characters
  (<=50 chars/row). Reduce budget proportionally to preserve prior result
  counts.

- **#2 — `ingest()` NULL-embedding != ghost** (#ghost, #ingest):
  All lessons passing quality gates (F1 min-length, F2 repetition, F3
  near-dup) now have `verified_at = NOW()` unconditionally. Previously,
  lessons without `commit_sha`/`artifact_hash` were ghost-excluded from
  recall. `ingest()` IS the verification gate; provenance tier still
  contributes to the aux ranking score but no longer gates visibility.

- **#4 — `recall_hybrid` O(n) → O(k log n)** (#recall, #performance):
  Rewrote single `raw_candidates` CTE into two bounded CTEs:
  `vec_candidates` (HNSW index scan, `LIMIT GREATEST(k*4, ef_search)`) and
  `bm25_candidates` (GIN index scan, `LIMIT GREATEST(k*4, 40)`).
  RRF window functions now operate over <=2×fetch_k rows, not n.
  Deterministic tie-breaker (`f.id ASC`) added to final ORDER BY.
  **#4 inclusion gated on host BENCHMARK** (Recall@10 >= 0.55, delta <5pp
  vs Python 2-phase, >=2000-row corpus). May revert to 0.9.1 by founder
  decision.

### Added

- **#1b — `project_id_filter` on `navigate_locate`** (#navigate, #parity):
  New 5th parameter `project_id_filter INT DEFAULT NULL`. Scopes candidates
  to a single project using the existing B-tree index
  (`pgmnemo_agent_lesson_project_idx`). Parity with `recall_hybrid` which
  has had `project_id_filter` since v0.4.0. Old 4-arg signature is dropped
  in migration.

- **#3 — `agent_lesson` content_type/blob_ref/doc_ref columns** (#schema):
  Three nullable columns: `content_type TEXT`, `blob_ref TEXT`,
  `doc_ref TEXT`. Gates future per-type dispatch (#5) and typed expand (#6)
  when G1 bench passes (>=50% coverage + >=3 distinct content_type values).

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.9.0';
```

### Breaking changes

None. All changes are additive (new parameter with DEFAULT, corrected budget
counter, new nullable columns). Existing callers are unaffected. However,
`navigate_locate` callers should be aware that budget accounting is now
correct — ~5x more IDs returned per equivalent budget.

---

## [0.8.3] — 2026-06-05

### Theme

**Documentation patch.** No schema, function, or scoring change — SQL is
byte-identical to v0.8.2. Fixes adopter-reported doc bugs surfaced by a cold
first-time-setup test.

### Fixed (docs)

- **`docs/INSTALL.md` "Verify install" smoke SQL was broken** — the very first
  command a new adopter runs failed twice: the bare `NULL` for the `vector(1024)`
  argument couldn't resolve the `ingest()` overload, and the example `lesson_text`
  (`'world'`) was under the 20-char minimum. Now uses `NULL::vector(1024)`,
  `3::smallint`, and a valid-length lesson.
- **MCP tool-argument contract was mis-documented** — `README.md` and
  `pgmnemo_mcp/README.md` implied `ingest` took a nested `metadata` dict, but the
  real schema exposes `text`/`role`/`topic`/`importance`/`project_id`/`commit_sha`/
  `artifact_hash`/`metadata` as **top-level** arguments. An agent following the old
  docs would silently mis-scope its lessons (`role="mcp_agent"` default). Documented
  the real arguments and their defaults.
- **Version drift** — install examples in `README.md` / `docs/INSTALL.md` pinned
  `v0.8.1` zips/`pgxn install pgmnemo==0.8.1`; bumped to the current release.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.8.3';
```
No-op at the SQL level (docs + `pgmnemo-mcp` package metadata only).

---

## [0.8.2] — 2026-06-05

### Theme

**Bug-fix release.** No schema changes. Fixes three real-adopter pain points
(agentplatform.ru/RZD: ghost rows, silent empty recall). Upgrade via
`ALTER EXTENSION pgmnemo UPDATE TO '0.8.2'`.

### Fixed

- **F1 — `traverse_temporal_window` include_unverified parsing** (#bug): the
  function compared `current_setting('pgmnemo.include_unverified', true) = 'on'`
  (string compare), rejecting `'true'` / `'1'` / `'yes'`. Fixed to
  `COALESCE(current_setting(...)::BOOLEAN, FALSE)`, matching every other recall
  function. Now accepts `on`, `true`, `1`, `yes` uniformly.

- **F2 — Silent empty recall when ghost lessons exist**: `recall_lessons()` and
  `recall_hybrid()` now emit a `NOTICE` when returning 0 rows and ghost lessons
  (`verified_at IS NULL`, ingested without provenance) exist in the same
  role/project scope:
  ```
  NOTICE: pgmnemo: N matching lesson(s) are unverified (ingested without
  commit_sha/artifact_hash) and excluded by default. SET
  pgmnemo.include_unverified = 'on' for this session, or pass provenance on ingest.
  ```
  The check is a single `COUNT(*)` on empty result only — no ranking or row
  changes.

- **F3 — Docs: `ALTER DATABASE SET` connection-pool footgun**: added explicit
  note in `docs/SQL_REFERENCE.md §"Disabling the provenance gate"` that
  `ALTER DATABASE ... SET pgmnemo.include_unverified` applies only to **new**
  connections; existing MCP/pooler connections must run
  `SET pgmnemo.include_unverified='on'` in their own session. Also documents
  that recall accepts `on/true/1/yes` for this GUC.

### Added

- **`pgmnemo-mcp` self-embedding via `EMBEDDING_SERVER`** (adopter request): the
  MCP server can now embed text itself through an OpenAI-compatible embeddings
  endpoint, so clients no longer need to supply vectors out of band. Set
  `EMBEDDING_SERVER` (and optionally `EMBEDDING_MODEL`, `EMBEDDING_DIM`, default
  1024) in the MCP env; `ingest` embeds the lesson text and `recall` embeds the
  query → real vector+BM25 hybrid recall. When `EMBEDDING_SERVER` is unset or
  unreachable, both fall back to the previous text-only (BM25) behaviour — never
  raises. Pure stdlib (`urllib`), no new dependency.
  ```json
  {"mcpServers": {"pgmnemo": {"command": "pgmnemo-mcp", "env": {
    "DATABASE_URL": "postgresql://user:pass@host:5432/db",
    "EMBEDDING_SERVER": "http://server:1234/v1/embeddings"
  }}}}
  ```

- **`pgmnemo-mcp` Docker image** (adopter request): a `pgmnemo_mcp/Dockerfile`
  lets the MCP run in a container so its `psycopg2`/`mcp` deps don't conflict with
  other libraries in Linux agent environments (where `pip install pgmnemo-mcp` was
  breaking). Build `docker build -t pgmnemo-mcp:0.8.2 pgmnemo_mcp/` and launch via
  `docker run -i --rm` in the MCP client config (see README §"Run via Docker").
  A `docker-publish.yml` workflow builds + pushes the image to Docker Hub
  (multi-arch amd64/arm64) on every release tag (operator sets DOCKERHUB_USERNAME/
  DOCKERHUB_TOKEN secrets; builds without pushing if unset).

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.8.2';
```
The `EMBEDDING_SERVER` feature is in the `pgmnemo-mcp` package only — `pip install -U pgmnemo-mcp` and add the env var. Embeddings must match the extension's `vector(1024)` (e.g. bge-m3); other dimensions are ignored (text-only fallback).

No migration steps. The upgrade is body-only function replacements.

---

## [0.8.1] — 2026-06-04

### Theme

**Documentation sprint + adoption-issue resolution.** No schema changes. The
extension SQL is identical to v0.8.0. Upgrade via
`ALTER EXTENSION pgmnemo UPDATE TO '0.8.1'`.

### Added

- **`AGENTS.md`** — new top-level canonical agent integration guide covering every
  user-facing function with working SQL examples and adoption recipes.
- **`docs/USAGE.md`** — new sections: `navigate_locate` / `navigate_expand`
  (v0.8.0 token-economy pattern), `reinforce()` / outcome-learning (v0.7.0),
  `reembed()` / `reembed_batch()` / `recompute_content()` (v0.8.0), `stats()`
  19-column reference, and GUC quick reference. Removes stale EXPERIMENTAL label
  from `recall_hybrid()`.
- **`docs/INSTALL.md`** — version references updated to v0.8.1 throughout (Paths
  1–4); no content changes to the Docker/COPY/GUC patterns (those were correct).

### Fixed (documentation)

- **#18** — GUC access pattern documented: `SHOW pgmnemo.*` fails on pure-SQL
  extensions; correct pattern is `current_setting('pgmnemo.X', TRUE)`. See
  `docs/INSTALL.md §"Reading the GUCs"` and the new GUC table in `docs/USAGE.md`.
- **#19** — Docker production install without a compiler: `docs/INSTALL.md` Path 3
  (custom Dockerfile with `ADD` + `COPY`) and Path 4 (vendored dir with `COPY`)
  both demonstrate zero-build-tool installation.
- **#20** — `pgmnemo.stats()` diagnostic SP: already shipped in v0.4.1 (14 cols)
  and v0.7.0 (19 cols incl. confidence distribution). Full 19-column reference now
  in `docs/USAGE.md §"Health check"`.
- **#24** — Orphan recovery: `docs/MIGRATION.md §B.5` documents detection via
  `SELECT orphan_count FROM pgmnemo.stats()` and recovery via
  `ALTER EXTENSION pgmnemo ADD FUNCTION`. Cross-referenced from `docs/USAGE.md`.
- **#41** — Stale automated issue from v0.7.1 release failure. Superseded by
  v0.7.2 packaging fix (clean-room CI install gate) and v0.8.0. No action needed.

### Positioning

- `README.md` tagline updated: single-plan multimodal fusion framing; version badge
  bumped to 0.8.1; navigate_locate/expand and outcome-learning added to Features.
- `POSITIONING.md`: differentiator claim expanded to include JSONB pushdown and
  graph proximity in one SQL plan; LME benchmark updated to 0.9604.
- `docs/WHY_PGMNEMO.md`: problem statement rewritten; navigate_locate quickstart
  example added; honest current state updated to v0.8.0.
- `ROADMAP.md`: internal strategy language removed; all shipped versions marked;
  v0.8.0 token-economy section added.

---

## [0.8.0] — 2026-06-03

### Theme

**Token-economy navigation API + production maintenance primitives.**
Introduces a two-phase locate/expand pattern for cost-aware retrieval:
`navigate_locate()` returns only IDs within a token budget; `navigate_expand()`
fetches content and optional graph neighbours on demand. Adds `reembed()`,
`reembed_batch()`, and `recompute_content()` for safe in-place updates that
coexist with live ingestion. Adds `source_type` column for origin classification.

### Added

- **`navigate_locate(query_embedding, query_text, token_budget_chars, jsonb_filter)`**
  Budget-bounded LOCATE. Uses the same hybrid RRF+aux+graph ranking formula as
  `recall_hybrid` but stops returning rows once the cumulative char sum of
  results exceeds `token_budget_chars`. JSONB predicate (`metadata @>
  jsonb_filter`) is pushed into the candidate scan to use the existing GIN
  index. Returns only `id`, `score`, `tokens_consumed`, and `navigation_path`
  (`'vector'`, `'bm25'`, or `'jsonb_gate'`) — no content.

- **`navigate_expand(ids, expand_fields, graph_expand_depth, graph_expand_threshold)`**
  On-demand content retrieval for caller-chosen IDs. Returns `lesson_text` plus
  optional `expand_detail` JSONB (selected keys from `metadata`). When
  `graph_expand_depth >= 1`, follows `causal`/`temporal` edges with
  `weight >= graph_expand_threshold` up to the specified depth, adding
  discovered neighbours with `navigation_path='graph_expand'`.

- **`reembed(lesson_id, new_vector)`** — Refreshes the embedding of a single
  active lesson. UPDATE-only: does not trigger the bitemporal `close+create`
  cycle. Updates `embedding_at` timestamp.

- **`reembed_batch(lesson_ids, new_vectors)`** — Batch version of `reembed`.
  Uses `FOR UPDATE SKIP LOCKED` to coexist safely with concurrent ingest.
  Returns the count of rows actually updated.

- **`recompute_content(lesson_id, new_text)`** — Updates `lesson_text` in
  place without creating a new bitemporal row. `content_hash`, `lesson_tsv`,
  and `updated_at` are refreshed automatically by PG cascades; `id`, edges,
  provenance, and `confidence` are preserved.

- **`agent_lesson.source_type TEXT`** — Origin classification column with
  `CHECK (source_type IN ('agent_authored','auto_captured','imported','system'))`,
  default `'auto_captured'`.

- **`agent_lesson.embedding_at TIMESTAMPTZ`** — Tracks the timestamp of the
  most recent embedding refresh. Backfilled to `updated_at` on upgrade.

### Fixed

- **`recall_hybrid` / `navigate_locate` graph-proximity is now a multiplicative
  tie-breaker, not an additive driver.** Previously the graph-proximity term
  could contribute ~10× the maximum retrieval (RRF) signal, so a lesson one
  causal/temporal hop from any top-5 anchor out-ranked a *perfect* vector+BM25
  match — new or unconnected lessons were effectively un-recallable regardless
  of relevance (rich-get-richer cold-start failure). Graph proximity now only
  re-orders already-relevant candidates. A perfect retrieval match reaches the
  top-3 both with the graph term off and at the default
  `graph_proximity_weight`, even alongside a dense connected hub cluster
  (regression-tested: `tests/sql/test_v080.sql` T18a/T18b).
- **BFS cycle guard + depth cap (5→2)** in the `navigate_locate` graph walk —
  bounds traversal cost and prevents revisiting nodes on cyclic graphs.

### Notes

- All existing function signatures unchanged (additive release).
- No compiled code; trusted PL/pgSQL throughout.
- `navigate_locate` + `navigate_expand` are designed to work together:
  locate IDs within budget first, then expand only the IDs you need.

---

## [0.7.2] — 2026-06-01

### Theme

**Packaging fix — the 0.7.1 distribution double-nested the extension dir
(`extension/extension/`) making it uninstallable from PGXN/GitHub; 0.7.2 ships a
correctly-structured dist. Added a CI clean-room install gate. No schema changes.**

### Fixed

- **Uninstallable 0.7.1 distribution (packaging).** The published 0.7.1 bundle
  nested the extension directory one level too deep
  (`pgmnemo-0.7.1/extension/extension/`). Every documented install path then
  copied files to the wrong location and `CREATE EXTENSION pgmnemo` failed with
  `could not open extension control file ".../pgmnemo.control": No such file or
  directory`. 0.7.2 produces a single, correctly-placed
  `pgmnemo-0.7.2/extension/` directory. The extension SQL itself was always
  correct; only the packaging was broken.

### Added

- **CI clean-room install gate.** A new job unzips the *built* release bundle
  into a pristine `pgvector/pgvector:pg17` container, installs it via the
  documented `cp -r .../extension/*` path, and asserts
  `CREATE EXTENSION vector; CREATE EXTENSION pgmnemo; SELECT pgmnemo.version()`
  returns the expected version. It runs both at PR time and as a hard gate on the
  GitHub Release + PGXN/PyPI publish — so a malformed dist can no longer ship
  green. The bundle builder also enforces a dist-shape guard that rejects
  `extension/extension/` double-nesting and dev/test/build cruft.

### Changed

- Single bundle builder: `scripts/build_pgxn_bundle.sh` is now the only path that
  assembles the release zip (the release workflow calls it instead of an inline
  copy block). Dev/test assets (`*_smoke.sql`, `test_*.sql`, `stress_*.sql`,
  `expected/*.out`) and orphan/dead-end migration variants are excluded from the
  bundle (they remain in-repo for the CI upgrade-path matrix).
- Install docs (`README.md`, `docs/INSTALL.md`) updated to the single-level
  `cp -r .../extension/*` copy and bumped to 0.7.2.

### Notes

- **No SQL schema change.** `pgmnemo--0.7.2.sql` is byte-identical to
  `pgmnemo--0.7.1.sql` (modulo the header version comment). The
  `pgmnemo--0.7.1--0.7.2.sql` upgrade is a documented no-op (no DDL) — it exists
  only so PostgreSQL bumps `pg_extension.extversion` to `0.7.2`.

---

## [0.7.1] — 2026-06-01

### Theme

**Calibration patch: `match_confidence` is now a usable [0,1] quality signal.**

v0.7.0 shipped `match_confidence` in `recall_hybrid()` output computed as
`final_score / 1.5`. This was correct for the `recall_lessons()` weighted-sum
path but wrong for the `recall_hybrid()` RRF path, where `final_score` is on
the RRF scale (~0.008–0.05). Good semantic hits (cosine=0.52) reported
`match_confidence ≈ 0.005` — unusable as an interpretable quality signal.

Fix: `match_confidence = vec_score` (cosine similarity, already [0,1] by
pgvector guarantee). Recall ranking (`ORDER BY final_score DESC`) is unchanged.

### Fixed

- **`recall_hybrid()` match_confidence mis-calibration (BUG-1, P0 user-facing)** —
  Changed from `LEAST(1.0, GREATEST(0.0, final_score / 1.5))` to
  `LEAST(1.0, GREATEST(0.0, v_score))`. On a genuine semantic hit with
  `vec_score=0.52`, `match_confidence` is now `0.52` instead of `0.0058`.
  On the text-only path (NULL embedding), `match_confidence = 0.0` (emit via
  existing RAISE NOTICE footgun guard). `recall_lessons()` is **not** affected —
  its weighted-sum scoring correctly uses `/1.5`. Reproduced live on a
  production corpus (~3,900 lessons, bge-m3 embeddings).

### Added

- **`pgmnemo.reinforce(p_lesson_ids BIGINT[], p_outcome TEXT) RETURNS INT`** —
  Batch confidence update overload. Iterates the array; silently skips missing
  lesson IDs (no `RAISE EXCEPTION` — bitemporal supersession/TTL is normal).
  Returns count of rows actually updated. Unknown `p_outcome` still raises.
  `neutral` outcome is a no-op and is not counted. Eliminates the N-round-trip
  per-call loop workaround needed to avoid a single missing ID aborting the
  whole transaction.

### Changed

- **`recall_hybrid()` COMMENT** — Updated to v0.7.1; corrects the
  `match_confidence` formula description and adds: *"graph_proximity contributes
  only when mem_edge is populated; with no edges the graph term is 0 (correct,
  not a bug)."*

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.7.1';
```

Function-only patch — no column additions, no table DDL. `recall_hybrid()` is
`DROP` + re-`CREATE` (same signature and return type, required for COMMENT update
consistency). `reinforce(BIGINT[], TEXT)` is additive.

> **Breaking note for match_confidence consumers:** If you had threshold logic
> like `WHERE match_confidence > 0.01` to filter "good" results, update to a
> meaningful cosine threshold (e.g. `> 0.3` for moderate similarity). The old
> values were ~0.005 for good hits; new values are the actual cosine similarity.

---

## [0.7.0] — 2026-05-29

### Theme

**Outcome-learning loop: agents now teach pgmnemo from experience.** v0.7.0 adds a
`confidence` column to `agent_lesson` (REAL, default 0.5, CHECK 0.0–1.0) tracking each
lesson's outcome track record, and a `reinforce(lesson_id, outcome)` function that
adjusts confidence based on success (+0.10), failure (−0.15), or neutral (no change),
clamped to [0.0, 1.0]. Confidence is wired into the `recall_hybrid()` scoring formula
as an auxiliary term, so high-confidence lessons rank above low-confidence ones in
tie-break situations. `stats()` gains five confidence-distribution columns
(`confidence_mean`, `confidence_p10`, `confidence_p50`, `confidence_p90`,
`confidence_below_threshold_count`) for operational monitoring.

`recall_hybrid()` output grows by two columns: `confidence REAL` (lesson outcome
track record) and `match_confidence REAL` (interpretable [0,1] quality indicator,
computed as `LEAST(1.0, GREATEST(0.0, final_score / 1.5))`).

Also ships: `ingest()` function guards — minimum lesson length (20 chars) and
repetitive-content detection (>80% single-token frequency) both raise exceptions
with descriptive messages, preventing low-quality lessons from polluting the corpus.

### Added

- **`confidence` column on `agent_lesson`** — `REAL NOT NULL DEFAULT 0.5`,
  `CHECK(confidence >= 0.0 AND confidence <= 1.0)`. Carries per-lesson outcome
  history from `reinforce()` calls.
- **`pgmnemo.reinforce(lesson_id BIGINT, outcome TEXT) RETURNS REAL`** — Updates
  `confidence` in-place and increments `success_count` or `fail_count`. Outcomes:
  `'success'` (+0.10), `'failure'` (−0.15), `'neutral'` (no change). Clamped to
  [0.0, 1.0]. Returns new `confidence` value. Raises `RAISE EXCEPTION` for unknown
  outcome values.
- **`success_count` and `fail_count` columns on `agent_lesson`** — `INTEGER NOT NULL
  DEFAULT 0`. Populated by `reinforce()`. Useful for filtering lessons with
  insufficient signal (count < N).
- **`confidence` and `match_confidence` output columns on `recall_hybrid()`** —
  `confidence REAL` is the lesson's outcome track record; `match_confidence REAL` is
  `LEAST(1.0, GREATEST(0.0, final_score / 1.5))` for interpretable quality reporting.
- **`ingest()` quality guards** — minimum length check (raises `'lesson_text too short
  (min 20 chars)'`) and repetition guard (raises `'repetitive content...'` when a
  single token exceeds 80% of all tokens).
- **`stats()` confidence distribution** — five new output columns:
  `confidence_mean REAL`, `confidence_p10 REAL`, `confidence_p50 REAL`,
  `confidence_p90 REAL`, `confidence_below_threshold_count BIGINT`.
- **`test_confidence` pg_regress test suite** — 9 test groups (T1–T9) covering the
  full v0.7.0 outcome-learning loop: column constraints, `reinforce()` paths,
  boundary clamping, recall ranking, footgun NOTICE, ingest guards, stats distribution.

### Changed

- **`recall_hybrid()` scoring formula** — auxiliary term now includes
  `0.025 * confidence` (was absent). High-confidence lessons score up to +0.025 above
  low-confidence lessons at equal semantic distance. Scoring change is incremental;
  existing benchmarks carry forward from v0.6.3.
- **`recall_hybrid()` COMMENT** — updated to v0.7.0; includes RRF (Cormack 2009)
  citation and confidence/match_confidence column documentation.

### Fixed

- **`graph_proximity` CTE alias bug in `recall_hybrid()`** — `FROM graph_walk WHERE
  gw.depth > 0` lacked the `gw` alias, causing `ERROR: missing FROM-clause entry for
  table "gw"` whenever the graph traversal CTE was reached. Fixed in both
  `pgmnemo--0.7.0.sql` and `pgmnemo--0.6.3--0.7.0.sql`.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.7.0';
```

Adds `confidence REAL DEFAULT 0.5`, `success_count INTEGER DEFAULT 0`,
`fail_count INTEGER DEFAULT 0` columns to `agent_lesson` with `LOCK TABLE` (brief).
Existing rows receive defaults; no data loss. `reinforce()` and `stats()` columns
added. All changes are backwards-compatible for read paths.

---

## [0.6.3] — 2026-05-24

### Theme

**Hotfix: `recall_lessons()` and `recall_hybrid()` are now callable without
`psycopg2.errors.AmbiguousColumn`.** This unblocks production deployments — the error
surfaced on every pgmnemo dispatch since v0.6.2 was installed. Root cause: PL/pgSQL
resolved `role` as the `RETURNS TABLE` OUT variable rather than the CTE column, even
when table-qualified (`al.role`, `r.role`). Fix: `#variable_conflict use_column`
directive added as the first line of both function bodies (compile-time only — no
execution change, no signature change, no scoring change).

Also ships: `pgmnemo.include_unverified` GUC semantics documentation (R2),
hybrid-mode activation conditions and SQL corpus probe (R3), and psycopg2
calling convention reference with working named-parameter example (R4).

Recall@10 metrics carry forward from v0.6.2 (0.9604 on LongMemEval-S).

### Fixed

- **R1 — `AmbiguousColumn` regression in `recall_lessons()` and `recall_hybrid()`**
  Added `#variable_conflict use_column` as the first statement in both function
  bodies (after `AS $`, before `DECLARE`). PL/pgSQL compile-time directive that
  instructs the name resolver to prefer column references over identically named
  OUT variables. No change to function signatures, query plans, index selection,
  scoring formulas, or output values. Affects both fresh-install
  (`pgmnemo--0.6.3.sql`) and incremental upgrade
  (`pgmnemo--0.6.2--0.6.3.sql`).

### Added

- **pg_regress: `role_no_ambiguity.sql`** + `extension/expected/role_no_ambiguity.out`
  Seeds one lesson with `role = 'role_v063_test'`, then asserts that both
  `recall_lessons()` and `recall_hybrid()` return `role = 'role_v063_test'` (boolean
  column checks). Catches any future re-introduction of the AmbiguousColumn regression.
  pg_regress test count: 17 → 18.

- **`scripts/smoke_recall_hybrid.py` — `smoke_recall_lessons()` function**
  New function appended to the existing smoke test, called from `main()`. Verifies:
  (1) `pgmnemo.recall_lessons` exists in `pg_proc`, (2) output columns match expected
  schema (catches AmbiguousColumn at column introspection stage), (3) role column
  returns correct value on vector-only path, (4) role column returns correct value
  on hybrid path (query_text provided). Both paths seed and clean up their own test
  data.

### Documentation

- **`docs/USAGE.md` — R2: `pgmnemo.include_unverified` semantics**
  New subsection clarifies the GUC is a **read-path filter only**: it widens
  `recall_lessons()`/`recall_hybrid()` to include lessons where `verified_at IS NULL`.
  It has no effect on the INSERT provenance gate — unverified lessons are still written
  and subject to `gate_strict` on insert. The separate `pgmnemo.gate_strict` GUC
  controls the write lifecycle.

- **`docs/USAGE.md` — R3: hybrid mode activation conditions**
  New subsection documents the three conditions required for hybrid mode:
  `pgmnemo.disable_hybrid` off, `query_text` non-null/non-empty,
  `query_embedding` non-null. Explicitly states there is **no corpus-size threshold**:
  hybrid fires for corpora of any size when the three conditions are met. Includes
  SQL probe query for checking lesson_tsv coverage and a backfill command.

- **`docs/USAGE.md` — R4: psycopg2 calling convention**
  New subsection with working code example using the recommended named-parameter
  `=>` syntax. Documents why psycopg2 has no native `vector` type and must receive
  embeddings as formatted strings with an explicit `::vector` cast. Includes a
  `format_vector(embedding)` helper function.

### Benchmark gate

```
gate_status:  PASS (bug_fix_smoke)
gate_type:    bug_fix_smoke (carry-forward from v0.6.2 real-DB bench)
recall@10:    0.9604 (carry-forward; no scoring change)
rationale:    #variable_conflict is a PL/pgSQL compile-time directive — no effect on
              query plan, index selection, ranking formula, or output values.
```

See [`benchmarks/gate/v0.6.3.json`](benchmarks/gate/v0.6.3.json).

---

## [0.6.2] — 2026-05-24

### Theme

RRF Fix-A landed as **sparse-safe RRF** (Cormack et al. 2009 proper RRF semantics).
Real-database benchmark on LongMemEval-S (N=500, bge-m3 1024d) shows **+1.13 pp recall@10**
(0.9491 → 0.9604) over the v0.5.1/v0.6.0/v0.6.1 `fusion_score` baseline,
with paired-t p-value **0.0166** (significant at α=0.05).

This resolves the v0.6.1 RRF deferral. The earlier "A-scale" variant
(ORDER BY `rrf_diag` with ROW_NUMBER tie-break) regressed by −22.44 pp on the
same corpus — root cause was arbitrary `bm25_rank` assigned to zero-BM25 items,
causing high-cosine answers without BM25 match to rank below BM25-matching non-answers.

### Changed (behavior)

- **`recall_hybrid()` ranking — sparse-safe RRF (F1)**
  CTE `rrf_ranked` now computes `bm25_rank_sparse` as `CASE WHEN bm25_score > 0
  THEN RANK() OVER (PARTITION BY (bm25_score > 0) ORDER BY bm25_score DESC) END`.
  Items with no BM25 match get a sentinel rank `n_candidates + 1` rather than
  arbitrary ROW_NUMBER positions, eliminating ordering corruption on small
  per-item corpora (~48 segments in LongMemEval session contexts).
  `rrf_score` output column now returns `rrf_sparse` (was `rrf_diag` diagnostic).
  Final `score` and `ORDER BY` use `rrf_sparse + _aux_scale*aux` (replacing
  `fusion_score`).

  Function signature unchanged (8 params). `_aux_scale = 0.01726` retained
  for tie-breaker; max(aux) ≈ 0.0026 stays well below adjacent RRF rank deltas.

### Added

- **pg_regress: `rrf_sparse.sql`** + `extension/expected/rrf_sparse.out`.
  Validates: PARTITION-BY-sparse rank assignment, sentinel handling for
  zero-BM25 candidates, `rrf_score` output column equals computed `rrf_sparse`.
  pg_regress test count: 16 → 17.

- **`benchmarks/scripts/run_v062_sparse_safe_bench.py`** — LongMemEval bench
  comparing baseline `fusion_score` vs `rrf_sparse` ordering. Reuses
  bge-m3 1024d cached embeddings from v0.6.1 (no model re-load).
  Outputs paired recall@1/5/10/20 + 95% CI + paired t p-value.

- **Migration script: `extension/pgmnemo--0.6.1--0.6.2.sql`** — incremental
  upgrade (CREATE OR REPLACE on `recall_hybrid`, no DROP needed; signature unchanged).

- **Fresh-install script: `extension/pgmnemo--0.6.2.sql`** — squashes
  0.0.1 → 0.6.2 chain. `default_version = '0.6.2'` in `pgmnemo.control`.

### Gate evidence

- `benchmarks/gate/v0.6.2.json` — `gate_status: PASS, gate_type: real_db_bench_significance`
- `benchmarks/longmemeval/results/v062_sparse_safe/metrics.json` — raw bench output

### Note on R1 (AmbiguousColumn in `recall_lessons` / `recall_hybrid`) — DEFERRED to v0.6.3

A production benchmark on an internal deployment
reported `psycopg2.errors.AmbiguousColumn: column reference "role" is ambiguous`
on every production call. Investigation: all bare `role` references inside
function bodies are already qualified as `al.role`. Root cause is PL/pgSQL
`variable_conflict` between the `RETURNS TABLE (... role TEXT, ...)` OUT
variable and the column — not a simple bare-reference issue. Fix requires
either a `#variable_conflict use_column` directive or renaming the OUT
column (backward-incompat). Deferred to v0.6.3 to investigate properly
rather than ship halfway.

Production workaround until v0.6.3: `pgmnemo_recall.py` already catches the
exception fail-open; calls return empty list (no recall context, but no crash).

### Compatibility

`recall_hybrid()` signature unchanged (8 params). Existing callers continue
to work; output column `rrf_score` now contains `rrf_sparse` instead of
`rrf_diag` — semantic change for callers that read this column for ranking.
Final ordering improves recall@10 by +1.13 pp on LongMemEval-S.

---

## [0.6.1] — 2026-05-23

### Theme

`as_of_ts` point-in-time recall (F2) + stress test benchmarks (F3, issue #29).
RRF Fix-A (F1) benchmarked and deferred to v0.6.2 after real-DB regression confirmed.

### Note on RRF Fix-A (F1) — DEFERRED to v0.6.2

**RRF Fix-A (ORDER BY `rrf_diag`) is NOT included in this release.**
Real-database benchmark on LongMemEval-S (N=500, bge-m3 1024d) confirmed a
**−22.44 pp regression** in recall@10 (0.9334 → 0.7090) when `rrf_diag` replaces
`fusion_score` as the primary sort key. Root cause: with RRF parameter k=60 and
small per-item corpora (~48 segments), rank differences compress severely —
documents without BM25 match receive arbitrary low `bm25_rank`, corrupting ordering
relative to pure vector matches. Benchmark artefacts:
`benchmarks/longmemeval/results/v0.6.1_realdb_20260523/`.

Fix-A targeted for v0.6.2 with corpus-size-adaptive k and additional validation.
`recall_hybrid()` ranking formula in v0.6.1 is **unchanged** from v0.5.1/v0.6.0
(`ORDER BY fusion_score`). The `rrf_score` output column retains `rrf_diag` as a
diagnostic value.

### Changed (behavior)

- **`recall_lessons()` — `as_of_ts TIMESTAMPTZ DEFAULT NULL` (6th param, F2)**
  Point-in-time recall for temporal agents and DAG bitemporal consistency.
  When `as_of_ts` is not NULL, only lessons where
  `t_valid_from ≤ as_of_ts < t_valid_to` are returned.
  Propagates to `recall_hybrid()` via transaction-local
  `pgmnemo.as_of_timestamp` GUC. Vector-only path applies filter directly
  in the `candidates` CTE WHERE clause.
  Backward compatible: `as_of_ts DEFAULT NULL` preserves all v0.5.1 and
  v0.6.0 call sites unchanged.

### Added

- **`as_of_ts` GUC propagation** — `set_config('pgmnemo.as_of_timestamp', ts, TRUE)`
  (transaction-local) lets `recall_hybrid()` read the bitemporal filter
  without signature changes. Callers can also set the GUC directly via
  `SET LOCAL pgmnemo.as_of_timestamp = '…'`.

- **pg_regress fixtures** — `as_of_ts.sql` (F2 predicate logic, GUC propagation)
  and `stress_recall.sql` (latency targets, HNSW index presence, scale bounds).
  Both are in the `REGRESS` target in `extension/Makefile`. Issue #29.

- **Stress benchmark script** — `benchmarks/scripts/stress_recall_large.py`.
  Tests `recall_lessons()` at 100K / 1M / 10M rows on a synthetic corpus.
  Targets: P99 ≤ 500ms (100K), ≤ 2000ms (1M), ≤ 8000ms (10M).
  Issue #29.

### Upgrade

```bash
ALTER EXTENSION pgmnemo UPDATE TO '0.6.1';
```

No table rewrite. DDL-only. Duration: <1 s.

```bash
-- Verify F2 (as_of_ts parameter):
SELECT pg_get_function_arguments('pgmnemo.recall_lessons'::regproc);
-- Should show 6th argument: "as_of_ts timestamp with time zone DEFAULT NULL"
```

### Rollback

See [`docs/MIGRATION.md`](docs/MIGRATION.md). No data migration; restore previous
extension version from backup if needed.

---

## [0.6.0] — 2026-05-22

### Theme

Temporal recall API (`as_of_ts`) + dedup observability + ghost-count metric.
Answers production-feedback RFC Q5/Q6/Q7. RRF Fix-A (rank-based fusion promotion) deferred
to v0.6.1 after failing the real-database benchmark gate.

### Note on RRF Fix-A

**RRF Fix-A is NOT included in this release.** Pre-release bench testing on
real production data showed a −2.40 pp regression in LME-S recall@10, which
did not pass the gate (p < 0.05, Δrecall@10 ≥ +1 pp required). Root cause:
auxiliary term contamination from A-norm denominator scaling — see
[`spec/v060/INVESTIGATION_FIX_A_REGRESSION.md`](spec/v060/INVESTIGATION_FIX_A_REGRESSION.md)
for full analysis. Fix-A is targeted for v0.6.1 after real-DB validation with
corrected normalization. The `recall_hybrid()` ranking formula is unchanged
from v0.5.1 (`ORDER BY fusion_score`); `rrf_score` output column retained as a
diagnostic value.

### Changed (behavior)

- **`recall_hybrid()` temporal filter** — reads `pgmnemo.as_of_timestamp`
  session variable, now set by `recall_lessons(as_of_ts)` parameter. Both dense
  vector and BM25 text branches filter to lessons valid at that timestamp
  (`t_valid_from ≤ as_of_ts < t_valid_to`). Ranking formula unchanged from
  v0.5.1.

### Note on bitemporal `as_of_ts` (also deferred)

During development, the v0.6.0 update script also rewrote `recall_lessons()` and
`recall_hybrid()` to support point-in-time recall via a new `as_of_ts` parameter.
The implementation introduced a CTE refactor that caused two distinct runtime
regressions (`AmbiguousColumn: role`, `UndefinedTable: graph_walk`), both caught
by `scripts/smoke_recall_hybrid.py` before publish.

Decision: ship v0.6.0 with `recall_lessons()` and `recall_hybrid()` **byte-identical
to v0.5.1**. The `as_of_ts` parameter and bitemporal filter return in v0.6.1
alongside the corrected RRF variant (A-scale) after real-DB validation.

### Added

- **`recall_lessons()` — `as_of_ts TIMESTAMPTZ DEFAULT NULL`** (6th param).
  Point-in-time recall scoping. When non-NULL, restricts results to lessons that
  were active at `as_of_ts`. Backward compatible: existing calls without this
  argument return the same results as before (current active lessons only).

- **`pgmnemo.stats()` — `ghost_count BIGINT`** — count of currently active
  lessons without provenance (`verified_at IS NULL`, meaning no `commit_sha` or
  `artifact_hash`). Use to track migration progress toward enabling the
  provenance gate (`include_unverified = off`). Target: `ghost_count < 5%` of
  `lesson_count`.

- **`ingest()` — dedup observability NOTICE** — `RAISE NOTICE` now fires when
  the dedup trigger closes a prior version and creates a new one. Message format:
  `"bitemporal close+create fired — closed N prior version(s) (content_hash=…).
  New lesson_id=…"`. Informational only; no behavior change. Capture via:
  `psql … 2>&1 | grep "bitemporal close+create fired"`.

### Upgrade

```bash
ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';
```

No table rewrite. DDL-only. Duration: <1 s.

- Added `pgmnemo.recall_stats` view for observability (R9): surfaces call counts and cumulative timing for `recall_lessons()`, `recall_hybrid()`, and `ingest()` via `pg_stat_user_functions`. Requires `track_functions = 'pl'` or `'all'` in `postgresql.conf`.

### Rollback

See [`docs/MIGRATION.md §0.5.1→0.6.0 §Rollback`](docs/MIGRATION.md).

---

## [0.5.2.post1] — 2026-05-22

### Theme

Post-release packaging fix: adds `README.md` to `pgmnemo-mcp` PyPI package so the
project page renders correctly. No code changes, no SQL changes.

### Fixed

- **`pgmnemo-mcp` PyPI page showed no description** — `pyproject.toml` referenced
  `readme = "README.md"` but the file was missing from `pgmnemo_mcp/`. PyPI displayed
  "The author of this package has not provided a project description." Added
  `pgmnemo_mcp/README.md` with install instructions, configuration table, tools
  reference, and links.

---

## [0.5.2] — 2026-05-22

### Theme

Patch release: MCP wheel packaging fix (Issue #32) + documentation improvements
+ CI regression prevention. No SQL schema change. Safe to upgrade from v0.5.1.

### Fixed

- **`pgmnemo-mcp` wheel was empty on install (Issue #32)** — `pip install pgmnemo-mcp`
  installed an empty package (no importable code) because `setuptools` could not
  find the source package in the `pgmnemo_mcp/` directory. Root cause: package
  source was at `pgmnemo_mcp/` but the `packages.find` root was set incorrectly.
  Fixed by moving source to a proper nested package layout and explicitly setting
  `[tool.setuptools.packages.find]` `where = ["."]` + `include = ["pgmnemo_mcp*"]`.
  `import pgmnemo_mcp` now works correctly after install.

### Added

- **`packaging-smoke` CI workflow** — `.github/workflows/packaging-smoke.yml` runs on
  every push and PR: builds the wheel, installs in a clean venv, imports `pgmnemo_mcp`,
  and verifies the wheel contains `.py` files. Prevents Issue #32 class of regression
  permanently.
- **`docs/RELEASE_CHECKLIST.md`** — manual pre-release gate with packaging smoke steps.
- **`pgmnemo_mcp/tests/test_import.py`** — pytest smoke test for importability.
- **`docs/MIGRATION.md` rollback procedure** (RFC Q6) — step-by-step rollback from
  v0.5.x back to v0.4.x using `ALTER EXTENSION pgmnemo UPDATE TO '0.4.1'` and
  `pg_restore` with `--section=pre-data`.
- **`docs/USAGE.md` temporal_boost calibration table** (RFC Q7) — concrete `temporal_boost`
  values (0.1/0.3/0.5/0.8/1.0) mapped to decay behaviour with guidance on choosing
  per workload type.

### Upgrade

```bash
pip install --upgrade "pgmnemo-mcp==0.5.2"
```

No `ALTER EXTENSION` needed — SQL schema is unchanged from v0.5.1.

---

## [0.4.0] — 2026-05-15

### Theme

Hybrid retrieval promoted to default — significant lift on conversational
memory workloads (LoCoMo), neutral on dense multi-doc retrieval (LongMemEval).

### Bench verdict

Real-DB benchmarks via the new router (`benchmarks/gate/v0.4.0.json`) vs
v0.3.0 baseline:

| Bench / scope | Metric | v0.3.0 | v0.4.0 | Δpp | p_corr | Verdict |
|---|---|---|---|---|---|---|
| LoCoMo session OVERALL | recall@5 | 0.6623 | 0.7230 | **+6.07** | 0.0010 | 🟢 IMPROVED |
| LoCoMo session OVERALL | recall@10 | 0.7951 | 0.8409 | **+4.15** | 0.0156 | 🟢 IMPROVED |
| LoCoMo session OVERALL | MRR | 0.5569 | 0.6365 | **+7.96** | <0.0001 | 🟢 IMPROVED |
| LoCoMo session open_domain | recall@5 | 0.7176 | 0.7907 | **+7.31** | 0.0148 | 🟢 IMPROVED |
| LoCoMo session open_domain | MRR | 0.5688 | 0.6667 | **+9.79** | 0.0009 | 🟢 IMPROVED |
| LongMemEval OVERALL | recall@10 | 0.9334 | 0.9334 | +0.00 | 1.0000 | neutral |
| LongMemEval OVERALL | MRR | 0.8472 | 0.8521 | +0.49 | 1.0000 | neutral |
| LoCoMo segment | (all) | (unchanged) | (unchanged) | 0.00 | 1.0000 | neutral |

5 significant improvements, 0 regressions across 24 LoCoMo session cells.
LongMemEval and LoCoMo segment hold steady — hybrid doesn't trigger when
query_text is NULL or when dense retrieval is already saturated (bge-m3 on LME).

Honest scope ([COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md) updated):

- ✅ Significant lift on conversational dialog retrieval (LoCoMo paper-canonical)
- ✅ No regression on any benchmark
- ❌ Does NOT close the BM25 gap on LongMemEval (BM25=0.982, pgmnemo=0.9334)
- ⚠️ v0.2.2 simulation predicted +12.7pp lift; real-DB measured +4.15pp on
   LoCoMo and +0.00pp on LongMemEval — sim overstated by 3-100x. New
   `docs/WORKFLOW.md §2.2` "PROVE BEFORE ADD" rule caught this before promotion.

### Added

- **Hybrid retrieval as default for `recall_lessons()`** — when `query_text`
  is non-empty AND `query_embedding` is non-NULL AND `pgmnemo.disable_hybrid`
  GUC is FALSE/unset, internally routes to `recall_hybrid()` with default
  weights (vec_weight=0.4, bm25_weight=0.4, rrf_k=60). Signature unchanged;
  output shape unchanged (12 columns); diagnostic `vec_score`/`bm25_score`/
  `rrf_score` columns exposed only via direct `recall_hybrid()` call.
- **`pgmnemo.disable_hybrid` GUC** — `SET pgmnemo.disable_hybrid = 'true'`
  restores strict v0.3.0 vector-only behaviour. Default FALSE.
- **`lesson_tsv` column + GIN index + auto-populating trigger** — moved from
  v0.2.2 EXPERIMENTAL opt-in to default extension install.
- **`recall_hybrid()` function** — moved from v0.2.2 opt-in to default install.
  Signature unchanged from v0.2.2.
- **`scripts/smoke_recall_hybrid.py`** — CI signature-stability smoke test
  (catches output-column rename bugs in ~10s vs ~5min bench script failure).
- **`benchmarks/scripts/bench_embed_cache.py`** — embedding cache (deterministic
  for `(text, model, max_seq)`). Reduces LongMemEval bench from ~52 min cold
  to ~3 min cached, LoCoMo from ~10 min to 14 seconds. Unlocks practical
  weight-tuning grid searches.

### Changed

- `docs/SQL_REFERENCE.md §2.5` — fixed incorrect documentation of
  `recall_hybrid()` output schema (was `hybrid_score`, actually `score`).
  Added `vec_score`, `bm25_score`, `rrf_k` parameter, and explicit "sort by
  score" guidance.
- `docs/COMPETITIVE_REALITY.md §1.2` updated — BM25 gap on LongMemEval
  remains (0.982 vs 0.9334); v0.4.0 does NOT close it. Future work via
  Stella V5 embedder (H-02) or workload-aware routing (H-future).
- `docs/COMPETITIVE_REALITY.md §5` updated — graph-feature deprecation
  deferred to v0.4.1 (separate cycle).

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.4.0';
```

Idempotent. Adopters who need strict v0.3.0 retrieval behaviour can opt out:

```sql
SET pgmnemo.disable_hybrid = 'true';
-- or persist:
ALTER SYSTEM SET pgmnemo.disable_hybrid = 'true';
SELECT pg_reload_conf();
```

### CI / release-gate verdict

`scripts/significance_test_extended.py` exit 3 (NEAR_THRESHOLD) due to
14 near-threshold cells on LoCoMo session (all positive direction). Release
notes include monitor watchlist for v0.4.1 follow-up:

- `multi_hop/MRR`: +9.55pp (p_corr=0.2949, n=321, may reach significance with v0.4.1 data)
- `multi_hop/recall@5`: +7.79pp (p_corr=0.6874)
- `adversarial/MRR`: +7.14pp (p_corr=0.7715)
- `single_hop/recall@10`: +3.62pp (positive but small n)
- `temporal/*`: small positive trends across 3 metrics (historically weakest category, watch)

---

## [0.5.1] — 2026-05-18

### Theme

Correctness and provenance-gate fixes. No recall algorithm change (Δ=0 confirmed
analytically). Safe to upgrade from v0.5.0.

### Fixed

- **`pgmnemo_mcp` write path** — `pgmnemo-mcp` server previously issued a raw
  `INSERT INTO pgmnemo.agent_lesson`, bypassing the `pgmnemo.ingest()` stored
  procedure. Writes now call `SELECT pgmnemo.ingest(...)`, which enforces the
  provenance gate (`gate_strict`) and sets `verified_at` automatically when a
  `commit_sha` or `artifact_hash` is present. All 16 MCP server tests updated.
- **`recall_lessons()` `temporal_boost` comment** — inline function comment and
  `COMMENT ON FUNCTION` incorrectly stated the formula as `γ=recency_weight²`.
  Corrected to `linear 90d half-life, coeff=pgmnemo.recency_weight` (matching
  the actual implementation).

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.5.1';
```

Also upgrade `pgmnemo-mcp` if installed:

```bash
pip install --upgrade pgmnemo-mcp==0.5.1
```

## [0.5.0] — 2026-05-17

### Theme

Bitemporality, MCP server, and operational hardening. The `pgmnemo-mcp` package
makes pgmnemo accessible to any MCP-compatible agent runtime without SQL. SQL
temporal history and content-hash dedup via H-07 close the data-lineage gap for
long-running agentic workflows.

### Added

- **`pgmnemo-mcp`** — MCP server package (`pgmnemo_mcp/`) exposing two tools:
  `pgmnemo.ingest(text, role, topic, importance, project_id, commit_sha, artifact_hash, metadata)`
  and `pgmnemo.recall(query, top_k)`.
  Backed by psycopg2 connection pool; configurable via `DATABASE_URL` / `MCP_PORT`.
  Entry point: `pgmnemo-mcp` console script. Smoke gate: `python -m pgmnemo_mcp --smoke`.

- **H-07 Bitemporality on `agent_lesson`** — `t_valid_from` / `t_valid_to` / `content_hash`
  columns added. Active rows have `t_valid_to = 'infinity'`. INSERT of a duplicate
  `content_hash` closes the prior row (trigger `trg_agent_lesson_bitemporal_close`).
  `pgmnemo.mem_item` view: active-only alias. `pgmnemo.as_of(ts)`: point-in-time query.

- **H-06 `pgmnemo.temporal_boost` GUC** — score multiplier for the recency component.
  `effective_γ = recency_weight × temporal_boost`. Default 1.0, range 0.0–20.0.
  `get_temporal_boost()` helper function. H-06 optimal (cell C6): `boost=10` with
  `recency_weight=0.05` → `effective_γ=0.5`.

- **R5 `pgmnemo.max_query_text_chars` GUC** — limits `query_text` in `recall_lessons()`
  and `lesson_text` in `ingest()`. Default 2000 chars; set to 0 to disable.
  Long input truncated with `RAISE NOTICE`.

- **R6 `pgmnemo.add_edge()` helper** — idempotent edge upsert. 5-param (convenience)
  and 6-param (full control) overloads. Conflict on `uq_mem_edge_active`
  `(source_id, target_id, relation_type WHERE valid_until IS NULL)`. Modes:
  `replace` (default) / `max` / `avg`. `edge_kind` auto-derived from `relation_type`.

- **`pgmnemo.ingest()` SQL function** — validated public write API replacing raw INSERT.
  R5 truncation, embedding dimension validation, auto `verified_at` stamping, `p_project_id`
  NOT NULL parameter. Signature: `(p_role, p_project_id, p_topic, p_lesson_text, p_importance,
  p_embedding, p_commit_sha, p_artifact_hash, p_metadata) RETURNS BIGINT`.

### Changed

- **`recall_lessons()` temporal_boost integration** — `effective_γ = recency_weight × temporal_boost`
  (backward-compatible: default 0.05 × 1.0 = 0.05). R5 query_text cap applied before
  all retrieval paths.

- **`temporal_boost` range widened 0.0–5.0 → 0.0–20.0** — allows stronger recency emphasis
  (e.g. `boost=10` with `recency_weight=0.05` → `effective_γ=0.5`) without changing the default.

- **`mem_edge` column names** — `lesson_a_id`/`lesson_b_id` renamed to `source_id`/`target_id`
  for consistency with `add_edge()` and `graph_walk` CTE internals. Adopters with positional
  INSERTs into `mem_edge` must update column lists; named-column callers using the old names
  must rename.

- **`docs/SQL_REFERENCE.md`** — `mem_edge` table schema updated to reflect `source_id`/`target_id`
  column names; idempotent INSERT pattern updated to use new names and partial index conflict target.

### Removed

- **`pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN)`** — 4-arg overload
  deprecated in v0.4.1 (RFC R10) is now **dropped**. Use the 5-arg form with
  an explicit `direction` parameter (`'forward'`, `'backward'`, or `'both'`).
  Migration: `extension/pgmnemo--0.4.1--0.5.0.sql`.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.5.0';
```

Idempotent. Breaking changes for adopters:
1. `mem_edge` direct INSERTs must rename `lesson_a_id`→`source_id`, `lesson_b_id`→`target_id`.
2. `traverse_causal_chain(4-arg)` callers must add `direction='forward'` (was deprecated in v0.4.1).
3. Positional callers of `recall_lessons()` must re-audit: output columns unchanged from v0.4.1.

---

## [0.4.1] — 2026-05-17

### Theme

Production hardening per first external production-user feedback (2026-05-16).
Operational observability + safe API deprecation + GUC default re-tuning.

### Bench verdict

`scripts/significance_test_extended.py` vs v0.4.0 (`benchmarks/gate/v0.4.0.json`):

| Bench / scope | Metric | v0.4.0 | v0.4.1 | Δpp | Verdict |
|---|---|---|---|---|---|
| LoCoMo session | recall@10 | 0.8409 | 0.8409 | 0.00 | neutral (router path unchanged) |
| LoCoMo session | MRR | 0.6365 | 0.6365 | 0.00 | neutral |
| LoCoMo segment | recall@10 | 0.3660 | TBD | TBD | recency_weight 0.08→0.05 may shift vector-only path |
| LongMemEval-S | recall@10 | 0.9334 | TBD | TBD | hybrid path saturated; expected neutral |

5 R-items from the production-feedback RFC shipped (#18, #20, #21, #24, #27). 3 R-items deferred
to v0.5.0 (#22, #23 helper SP portion, #27 final removal). 2 R-items deferred
to v0.6.0 (#25, #26).

### Added

- **`pgmnemo.stats()`** — single-row diagnostic SP with 13 health-check signals
  (R3): version, lesson_count, embedded_count, embedding_coverage_pct,
  tsv_coverage_pct, mem_edge_count, recency_weight, ef_search,
  importance_weight, hybrid_enabled, recall_hybrid_available,
  oldest_lesson_age_days, orphan_count. `LANGUAGE sql STABLE`, <50ms on
  N=10k corpus. Issue #20.
- **`recall_lessons()` diagnostic columns** (R4): output shape grew 12 → 15
  columns. Appended `vec_score`, `bm25_score`, `rrf_score`. Hybrid path:
  all 3 populated. Vector-only path: vec_score populated, bm25_score and
  rrf_score are NULL (informative NULL — tells the caller which path fired).
  Backward compatible for named-column callers; positional callers re-audit.
  Issue #21.
- **`orphan_count` signal in `pgmnemo.stats()`** (R7) — detects functions in
  `pgmnemo` schema not owned by the extension. Typically caused by intermediate
  manual SQL patches. Recovery recipe in `docs/MIGRATION.md §B.5`. Issue #24.
- **`docs/INSTALL.md`** (NEW, shipped 2026-05-16) — 4-path install guide:
  PGXN, GitHub release zip, **Docker production via Dockerfile bake** (the
  canonical Docker path), vendored extension directory. Plus "Reading the
  GUCs" section explaining `SHOW` vs `current_setting` and "Common gotchas"
  table. Issue #19.
- **`docs/SQL_REFERENCE.md §1.1` mem_edge population contract** (shipped
  2026-05-16) — canonical `INSERT ... ON CONFLICT` pattern, `relation_type`
  → `edge_kind` mapping, 3 update-policy modes (replace/max/avg). Docs
  portion of R6; helper SP `pgmnemo.add_edge()` deferred to v0.5.0 per
  issue #23 comment.
- **`docs/RELEASE_CHECKLIST.md`** (NEW) — canonical end-to-end Phase 0–7
  release procedure with SQL migration conventions reference + rollback
  procedure. Closes 6 of 11 workflow audit gaps (audit 2026-05-16).
- **`scripts/build_pgxn_bundle.sh`** — reproducible bundle build with
  META.json consistency validation.
- **CI multi-PG compatibility matrix** — `compat-matrix` job runs against
  PG 14/15/16 with `continue-on-error: true` for visibility (PG 17 remains
  the blocking gate). See `README.md` Compatibility matrix.
- **CI upgrade-path test** — `upgrade-path-test` job verifies
  `ALTER EXTENSION pgmnemo UPDATE TO '0.4.1'` chain from v0.2.1, v0.3.0,
  v0.4.0 on every push.
- **`docs/CONTRIBUTING.md` and `SECURITY.md`** — workflow pointers + supported
  version matrix updated for v0.4.1.

### Changed

- **`pgmnemo.recency_weight` default 0.08 → 0.05** (R1 code part). Per an
  internal ablation on a production corpus (N=1081, age 0-365d). Adopters who set this
  via `ALTER SYSTEM` keep their values across upgrade; only the function-default
  fallback changes. To explicitly use the previous default: `SET pgmnemo.recency_weight = '0.08'`.
- **`docs/SQL_REFERENCE.md §3 GUCs` rewritten** — 5 recall scoring GUCs +
  2 ingest GUCs + multi-tenant scoping, with v0.4.1 defaults and
  default-change history table. Earlier doc showed stale 0.08 default;
  fixed in commit `1f12c12`.
- **`docs/USAGE.md` Tuning section** — switched from documenting upstream
  `hnsw.ef_search` to documenting the pgmnemo wrapper GUC; added recency-weight
  tuning subsection with the ablation citation.
- **README** — added Compatibility matrix table (PG 14-17 + pgvector range);
  added pointer block to WORKFLOW + RELEASE_CHECKLIST + BENCHMARK_PROTOCOL
  for maintainer audience.
- **`docs/RELEASE_PROCESS.md` marked DEPRECATED** — superseded by
  WORKFLOW.md + RELEASE_CHECKLIST.md. Mapping table in the document header
  shows which canonical doc replaces each old section.

### Deprecated

- **`pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN)`** — the
  4-arg overload now emits `RAISE NOTICE` on every call and delegates to
  the 5-arg form with `direction='forward'`. **Will be REMOVED in v0.5.0.**
  Update callers to pass `direction` explicitly (R10).
  Issue #27.

### Fixed

- `docs/SQL_REFERENCE.md §2.5` corrected (`recall_hybrid` output column was
  documented as `hybrid_score`, actually `score`) — fixed in v0.4.0 cycle but
  carried forward by reference here.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.4.1';
```

Idempotent. Adopters with `recall_lessons()` callers using positional argument
binding (not named) MUST re-audit: output column count grew 12 → 15. Named-column
callers (`SELECT lesson_id, score FROM pgmnemo.recall_lessons(...)`) are unaffected.

Adopters who relied on the deprecated 4-arg `traverse_causal_chain()` will see
a `NOTICE` on every call in v0.4.1; update calls to pass `direction='forward'`
explicitly before v0.5.0 ships.

### Operator scheduling tip

If you set `expires_at` on lessons, schedule `pgmnemo.evict_expired_lessons()`
via `pg_cron`:

```sql
SELECT cron.schedule('pgmnemo-evict', '0 3 * * *',
                     'SELECT pgmnemo.evict_expired_lessons()');
```

R8 (project-scoped TTL eviction) is scheduled for v0.6.0; until then,
`evict_expired_lessons()` is global.

### Workflow

This is the first release shipped under the formalised
[docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) Phase 0–7 procedure.
Maintainer audit (2026-05-16) found 11 gaps in the pre-v0.4.1 workflow; 6 are
closed in this release (canonical end-to-end checklist, reproducible bundle
build, deprecation of stale RELEASE_PROCESS doc, cross-linking, multi-PG
visibility, upgrade-path testing).

---

## [0.3.1] — 2026-05-13

### Theme

Hygiene foundation — no recall-algorithm change. The release that closes the
documentation/process gaps surfaced by the v0.2.x → v0.3.0 audit (see
`docs/WORKFLOW.md §1` for the post-mortem).

### Bench verdict

Per `scripts/significance_test_extended.py` against the v0.3.0 baseline
(`benchmarks/gate/v0.3.0.json`): **neutral on all 3 benches** — no SQL change,
no recall delta possible. The release is hygiene-only.

### Added

- **`docs/WORKFLOW.md`** — canonical development discipline document. Defines
  customer-first hypothesis declaration, per-cell bench gate, deprecation by
  absence of evidence, and 2–4 week release cycle.
- **`docs/BENCHMARK_PROTOCOL.md`** — two-phase architecture (corpus snapshot
  reuse + per-version retrieval test), frozen parameters table, gate decision
  matrix, CI integration plan.
- **`docs/SQL_REFERENCE.md`** — every public SQL function (version, ingest,
  recall_lessons, recall_lessons_pooled, recall_hybrid, traverse_causal_chain,
  traverse_temporal_window), all GUCs, RLS behaviour, deprecation log.
- **`docs/MIGRATION.md` Part B** — in-place version-to-version upgrade paths
  v0.1.x → v0.3.0, per-version backfill requirements, generic dump+restore
  rollback policy.
- **`benchmarks/METRICS_BY_VERSION.md`** — single source of truth for
  "which version produced which number." Per-(dataset × embedder × mode)
  tables, append-only at every release.
- **`benchmarks/gate/`** — release pre-push snapshot files (`v<tag>.json`)
  that consolidate every real-DB metrics.json for a release; CI uses these
  for the mechanical gate decision.
- **`scripts/significance_test_extended.py`** — per-category z-test with
  Holm-Bonferroni correction; exit codes 0/1/2/3 drive the release gate.
- **`scripts/render_progression.py`** — pure-SVG per-bench small-multiples
  line charts with CI95 bands.
- **`scripts/render_full_history.py`** — Tufte-style sparkline table with all
  metrics × all versions.
- **`scripts/render_executive_scorecard.py`** — single-page PASS/WATCH/FAIL
  scorecard for non-technical readers.
- **`ROADMAP.md` v2** — customer-driven per-version plan to v1.0. Old
  spec-driven roadmap archived.
- **CI bench-gate** — `.github/workflows/release.yml` blocks tag push when
  `benchmarks/gate/v<tag>.json` is missing or significance test exits 2.
  Soft check in `ci.yml` warns PRs that touch SQL but don't update the gate.

### Fixed

- GitHub Issues #12 (release coherence), #13 (docs/API coherence), #14
  (install/upgrade contract), #15 (migration guide), #16 (benchmark protocol)
  — all closed; see commits in the v0.3.1 cycle.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.3.1';
```

Empty upgrade script (no SQL changes); the version bump tracks
documentation/process improvements only.

---

## [0.3.0] — 2026-05-10

### Fixed

- **P0: `edge_type` → `relation_type` in migration S3 backfill** — the `UPDATE pgmnemo.mem_edge SET edge_kind = ...` backfill in the 0.2.1→0.3.0 migration script referenced a non-existent column `edge_type` instead of the correct `relation_type` column. On any database with existing `mem_edge` rows this caused `ERROR: column "edge_type" does not exist`, preventing the migration from completing. Fixed: all `edge_type` references in S3 replaced with `relation_type`.
- **P0: `edge_type` → `relation_type` in `traverse_causal_chain()` S8** — the recreated `traverse_causal_chain()` function in S8 of the migration also referenced `me.edge_type` in the WHERE clause (both forward and backward BFS branches). Fixed: all `edge_type` references replaced with `relation_type` in S8.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.3.0';
```

---

## [0.2.2] — 2026-05-10 (candidate)

### Added

- **`pgmnemo.recall_hybrid()` — vector + BM25 weighted fusion** (**EXPERIMENTAL — opt-in only, NOT default**) — new function combining dense cosine retrieval with BM25-class sparse retrieval (`ts_rank_cd` on `lesson_tsv`). Formula: `0.4×cosine + 0.4×ts_rank_cd(lesson_tsv, q, 32)` (plus minor importance/recency/provenance components). Union retrieval: candidates matched by **either** embedding cosine **or** BM25 text match. Returns `rrf_score` diagnostic column (`1/(rrf_k+vec_rank) + 1/(rrf_k+bm25_rank)`). `recall_lessons()` is unchanged and remains the default. **Bench results (simulation, 2026-05-10):** LoCoMo recall@10 +12.7pp vs vector-only (all 5 question types positive, statistically significant, CIs disjoint); LongMemEval MRR +5.8pp (p=0.005, significant), recall@10 +1.5pp (p=0.308, not significant — within noise at high baseline 0.93). Try `recall_hybrid()` if your task is MRR-sensitive or your corpus has keyword-matchable queries alongside semantic ones. WG decision: `spec/v2/pgmnemo/HYBRID_DECISION_2026-05-10.md`.
- **Migration script** `extension/pgmnemo--0.2.1--0.2.2-hybrid.sql` — idempotent `CREATE OR REPLACE FUNCTION`, backward-compatible (existing `recall_lessons()` unchanged).
- **Benchmark script** `benchmarks/scripts/run_longmemeval_hybrid.py` — LongMemEval evaluation harness for `recall_hybrid()` with gap-analysis reporting vs. vector-only and BM25 baselines.

### Upgrade

```sql
\i extension/pgmnemo--0.2.1--0.2.2-hybrid.sql
```

---

## [0.2.1] — 2026-05-09

### Added

- **`traverse_causal_chain(direction)` parameter** (W2.2 / F5) — adds `direction TEXT DEFAULT 'forward'` parameter. `'forward'` follows source→target edges (existing behaviour, backward-compatible). `'backward'` follows target→source edges for reverse traversal. `'both'` traverses all edges. Input validation raises `EXCEPTION` on invalid values. Cycle guard via path array applies to all directions.
- **`pgmnemo.ef_search` GUC** (F2) — `SET LOCAL pgvector.hnsw.ef_search` applied at `recall_lessons()` entry from `pgmnemo.ef_search` GUC (default 100, clamped 10–500).
- **Graph-proximity mixin in standard upgrade path** (F3) — `pgmnemo--0.2.0-step4-recall-mixin.sql` content folded into the v0.2.0.1→0.2.1 upgrade script (was supplemental-only).
- **Row-Level Security multi-tenant isolation** (W2.3 / Q5) — `pgmnemo.tenant_id` GUC gates `agent_lesson` by `project_id` and `mem_edge` by endpoint ownership. Empty/unset = service-account bypass. Policies are idempotent (DROP IF EXISTS before CREATE).

### Fixed

- **`recall_lessons()` IN-param/RETURNS TABLE collision on `project_id`** (INS-029 v2) — IN-param `project_id INT` collided with the `RETURNS TABLE` column of the same name. Fix: IN-param renamed to `project_id_filter`; all internal `recall_lessons.project_id` references updated accordingly. Backport of the same pattern as the `role`→`role_filter` fix in v0.1.4.1/v0.2.0.1.

### Changed

- **`pgmnemo.recency_weight` default lowered** (F1) — from `0.20` to `0.08` (pending REC-1 ablation confirmation). Operator can override via `ALTER SYSTEM SET pgmnemo.recency_weight = '<value>'; SELECT pg_reload_conf();`.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.1';
```

---

## [0.2.0.1] — 2026-05-04

### Fixed

- **`traverse_temporal_window()` numeric → double precision cast** (INS-030) — comparison between a `NUMERIC` intermediate value and `DOUBLE PRECISION` caused a type-mismatch error at runtime on PostgreSQL 14/15. Cast now explicit throughout the function body.
- **`recall_lessons()` IN-param/RETURNS TABLE collision** (INS-029) — IN-param `role` renamed to `role_filter` (backport of v0.1.4.1 fix; see below).
- **Idempotent upgrade DDL** (INS-031) — `ADD COLUMN IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS` guards added across all `0.1.4→0.2.0` upgrade scripts (backport of v0.1.4.1 fix).
- **`recall_lessons_pooled()` post-collision smoke** (Action #7) — confirmed pooled wrapper correctly delegates to the renamed `role_filter` parameter after the collision fix.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.0.1';
```

---

## [0.1.4.1] — 2026-05-04 (maintenance branch)

### Fixed

- **`recall_lessons()` IN-param/RETURNS TABLE collision** (INS-029, P0) — PL/pgSQL raised `ERROR: parameter name "role" used more than once` because the IN-param `role TEXT` collided with the `RETURNS TABLE` column of the same name. The flagship function never compiled on a fresh install. Fix: IN-param renamed to `role_filter`; all callers updated.
- **Idempotent upgrade DDL** (INS-031) — `ADD COLUMN IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS` guards applied across all upgrade scripts so re-running a patch on an already-upgraded database no longer raises duplicate-object errors.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.4.1';
```

---

## [0.2.0] — 2026-05-04

### Added

- **`pgmnemo.mem_edge` DDL** (closes RFC §3) — directed typed edge table between `agent_lesson` rows.
  - Columns: `source_id`, `target_id`, `relation_type` (CAUSED_BY, SUPERSEDES, CO_OCCURRED, DERIVED_FROM, or user-defined), `weight REAL` [0.0–1.0], bitemporality (`valid_from`/`valid_until`), `commit_sha`, `metadata JSONB`.
  - Three covering indexes: forward/reverse traversal on `(source_id, relation_type)` and `(target_id, relation_type)` with `WHERE valid_until IS NULL`; temporal range index on `(valid_from, valid_until)`.
  - `CONSTRAINT ck_no_self_loop`: prevents `source_id = target_id`.

- **`pgmnemo.traverse_causal_chain(start_id, max_depth, relation_types, only_active)`** (closes RFC §4) — recursive CTE walk of the causal edge graph.
  - Returns `(lesson_id, depth, path BIGINT[], path_weight, role, topic, lesson_text, importance, created_at, commit_sha, verified_at)`.
  - Cycle-safe via accumulated path array. Fail-safe: returns zero rows if `start_id` missing.
  - `max_depth` default 5; `relation_types` default `ARRAY['CAUSED_BY']`; `only_active` default `TRUE`.

- **`pgmnemo.traverse_temporal_window(start_id, window_interval, include_unlinked, role_filter, project_id_filter, k)`** (closes RFC §5) — co-temporal episode discovery.
  - Returns lessons whose `created_at` falls within `±window_interval` of the anchor lesson. Window hard-capped at 30 days.
  - `linked=TRUE` when a `mem_edge` (either direction) exists between the row and `start_id`.
  - Ghost-lesson exclusion controlled by `pgmnemo.include_unverified` GUC (default off).

- **Graph-proximity mixin for `recall_lessons()`** — integrates BFS graph traversal into scoring.
  - Updated scoring formula: `0.4×cosine + 0.2×importance + γ×recency + 0.1×prov_strength + δ×graph_proximity`.
  - `graph_proximity = MAX(1 - depth/max_depth)` via BFS through `CAUSED_BY`, `CO_OCCURRED`, `DERIVED_FROM` edges from top-5 cosine anchors (max_depth=5).
  - New GUC `pgmnemo.graph_proximity_weight` (default `0.2`, clamped to `[0.0, 0.5]`).

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.0';
```

Or from a fresh install:

```sql
CREATE EXTENSION pgmnemo CASCADE;   -- installs 0.2.0 directly
```

---

## [0.1.4] — 2026-05-04

### Added

- **State machine for `agent_lesson`** (closes [#3](https://github.com/pgmnemo/pgmnemo/issues/3))
  - New `state TEXT` column (default `'draft'`), constrained to 9 lifecycle values:
    `draft`, `candidate`, `validated`, `canonical`, `deprecated`, `superseded`, `archived`, `rejected`, `conflicted`.
  - `state_changed_at TIMESTAMPTZ` — auto-set on every state change.
  - `pgmnemo.agent_lesson_state_transition` table — explicit allowed-transition pairs.
  - `pgmnemo.transition_lesson(lesson_id BIGINT, new_state TEXT)` — enforces the DAG; raises on invalid transition.

- **Provenance FK columns** (closes [#4](https://github.com/pgmnemo/pgmnemo/issues/4))
  - `source_run_id BIGINT NULL` — soft FK to the orchestrator `agent_run` row that produced this lesson.
  - `source_task_id BIGINT NULL` — soft FK to the orchestrator `tasks` row.
  - Partial indexes `ix_pgmnemo_lesson_source_run` and `ix_pgmnemo_lesson_source_task` (WHERE NOT NULL).
  - Columns are intentionally not hard `REFERENCES`-constrained so the extension remains portable across host schemas.

- **TTL / `expires_at`** (closes [#5](https://github.com/pgmnemo/pgmnemo/issues/5))
  - `expires_at TIMESTAMPTZ NULL` — optional hard expiry; `NULL` = never expires.
  - `pgmnemo.evict_expired_lessons()` — deletes rows where `expires_at < NOW()`; returns eviction count. Safe to call on a schedule.
  - Partial index `ix_pgmnemo_agent_lesson_expires` keeps eviction scans cheap.

### Fixed

- **`pgmnemo.version()` dynamic lookup** (closes [#1](https://github.com/pgmnemo/pgmnemo/issues/1))
  - `version()` previously returned a hard-coded string baked at build time. After `ALTER EXTENSION pgmnemo UPDATE` the reported version was stale.
  - Now reads `extversion` from `pg_catalog.pg_extension` at call time — always accurate.

### Upgrade

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.4';
```

Or from a fresh install:

```sql
CREATE EXTENSION pgmnemo CASCADE;   -- installs 0.1.4 directly
```

---

## [0.1.3] — 2026-04-29

### Added

- `verifier_role TEXT` column on `agent_lesson` — records which agent role validated the lesson.

---

## [0.1.2] — 2026-04-28

### Added

- Tri-state `prov_strength` (`hard` / `soft` / `none`) on `agent_lesson`.
- `recall_lessons_pooled()` wrapper — cross-project recall for shared-context queries.

---

## [0.1.1] — 2026-04-27

### Added

- `recency_weight` GUC — tune the time-decay component of the hybrid recall score without restarting the server.

---

## [0.1.0] — 2026-04-26

### Added

- HNSW vector index via `pgvector` — fast approximate nearest-neighbour recall.
- `pgmnemo.ingest()` — provenance-gated write API; requires `commit_sha` or `artifact_hash`.
- `pgmnemo.recall_lessons()` — hybrid scoring: cosine similarity + BM25 full-text + recency decay.
- Role + `project_id` composite scoping.
- `recall_lessons_pooled()` (cross-project variant).

---

## [0.0.1] — 2026-04-20

Initial schema: `pgmnemo.agent_lesson` table + basic HNSW index.

---

<!-- Keep-a-Changelog compare links — update top entry on each release -->
[unreleased]: https://github.com/pgmnemo/pgmnemo/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/pgmnemo/pgmnemo/compare/v0.8.3...v0.9.0
[0.8.3]: https://github.com/pgmnemo/pgmnemo/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/pgmnemo/pgmnemo/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/pgmnemo/pgmnemo/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/pgmnemo/pgmnemo/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/pgmnemo/pgmnemo/compare/v0.6.3...v0.7.0
[0.6.3]: https://github.com/pgmnemo/pgmnemo/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/pgmnemo/pgmnemo/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/pgmnemo/pgmnemo/compare/v0.5.2.post1...v0.6.0
[0.5.2.post1]: https://github.com/pgmnemo/pgmnemo/compare/v0.5.2...v0.5.2.post1
[0.5.2]: https://github.com/pgmnemo/pgmnemo/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/pgmnemo/pgmnemo/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/pgmnemo/pgmnemo/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/pgmnemo/pgmnemo/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/pgmnemo/pgmnemo/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.2.0.1...v0.2.1
[0.2.0.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.2.0...v0.2.0.1
[0.2.0]: https://github.com/pgmnemo/pgmnemo/compare/v0.1.4.1...v0.2.0
[0.1.4.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.1.4...v0.1.4.1
[0.1.4]: https://github.com/pgmnemo/pgmnemo/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/pgmnemo/pgmnemo/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/pgmnemo/pgmnemo/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/pgmnemo/pgmnemo/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/pgmnemo/pgmnemo/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/pgmnemo/pgmnemo/releases/tag/v0.0.1

