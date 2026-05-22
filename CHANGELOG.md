# Changelog

All notable changes to `pgmnemo` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.6.0] — 2026-05-22

### Theme

RRF Fix-A (rank-based fusion replaces linear fusion) + temporal recall API
(`as_of_ts`) + dedup observability + ghost-count metric. Answers Agency RFC
Q4/Q5/Q6/Q7.

### Bench verdict

Benchmark gate (p < 0.05, Δrecall@10 ≥ +1 pp on held-out evaluation set) to be
published in the v0.6.1 QA report. Simulated analysis from v0.5.2 spec work
projects +1.5–2 pp recall@10 lift from Fix-A.

### Changed (behavior)

- **`recall_hybrid()` Fix-A** — `ORDER BY` now uses a rank-based fusion score
  normalized to [0,1] (`rank_score / max_rank_score`) instead of a weighted
  linear combination of raw similarity values. Literature basis: Cormack et al.
  (SIGIR 2009, Reciprocal Rank Fusion). Output columns unchanged; `rrf_score`
  column value unchanged.
- **`recall_hybrid()` temporal filter** — reads `pgmnemo.as_of_timestamp`
  session variable, now set by `recall_lessons(as_of_ts)` parameter. Both dense
  vector and BM25 text branches filter to lessons valid at that timestamp
  (`t_valid_from ≤ as_of_ts < t_valid_to`).

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
  deprecated in v0.4.1 (Agency RFC R10) is now **dropped**. Use the 5-arg form with
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

Production hardening per Agency RFC (first external production user, 2026-05-16).
Operational observability + safe API deprecation + GUC default re-tuning.

### Bench verdict

`scripts/significance_test_extended.py` vs v0.4.0 (`benchmarks/gate/v0.4.0.json`):

| Bench / scope | Metric | v0.4.0 | v0.4.1 | Δpp | Verdict |
|---|---|---|---|---|---|
| LoCoMo session | recall@10 | 0.8409 | 0.8409 | 0.00 | neutral (router path unchanged) |
| LoCoMo session | MRR | 0.6365 | 0.6365 | 0.00 | neutral |
| LoCoMo segment | recall@10 | 0.3660 | TBD | TBD | recency_weight 0.08→0.05 may shift vector-only path |
| LongMemEval-S | recall@10 | 0.9334 | TBD | TBD | hybrid path saturated; expected neutral |

5 R-items from Agency RFC shipped (#18, #20, #21, #24, #27). 3 R-items deferred
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

- **`pgmnemo.recency_weight` default 0.08 → 0.05** (R1 code part). Per Agency
  ablation on production corpus (N=1081, age 0-365d). Adopters who set this
  via `ALTER SYSTEM` keep their values across upgrade; only the function-default
  fallback changes. To explicitly use the previous default: `SET pgmnemo.recency_weight = '0.08'`.
- **`docs/SQL_REFERENCE.md §3 GUCs` rewritten** — 5 recall scoring GUCs +
  2 ingest GUCs + multi-tenant scoping, with v0.4.1 defaults and
  default-change history table. Earlier doc showed stale 0.08 default;
  fixed in commit `1f12c12`.
- **`docs/USAGE.md` Tuning section** — switched from documenting upstream
  `hnsw.ef_search` to documenting the pgmnemo wrapper GUC; added recency-weight
  tuning subsection with Agency ablation citation.
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
  Update callers to pass `direction` explicitly (R10, Agency-specific).
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
