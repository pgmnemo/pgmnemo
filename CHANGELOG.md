# Changelog

All notable changes to `pgmnemo` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

- **Graph-proximity mixin for `recall_lessons()`** (PGMNEMO-V020-4) — integrates BFS graph traversal into scoring.
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
