# Changelog

All notable changes to `pgmnemo` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
