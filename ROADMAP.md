# pgmnemo Roadmap

**Effective:** 2026-06-20

---

## Strategic frame

pgmnemo is **agent memory that learns which lessons worked — ranked by outcome, not timestamp, auditable in plain SQL.** Install in under 5 minutes; replace ad-hoc memory code with two SQL calls. No new service. No data egress. EXPLAIN-able ranking.

**Causal moat (6-step chain):** `ingest()` → `recall_hybrid()` → confidence-weighted ranking → agent acts → outcome observed → `reinforce()` updates confidence. Every step is a SQL call. The chain is inspectable, regression-testable, and closes the feedback loop that recency-weighted memory cannot: a lesson's rank reflects whether it *worked*, not when it was written.

**Architecture moat:** Vector + BM25 + graph proximity + JSONB predicate pushdown in one SQL query plan — plus provenance-gated writes and token-economy navigation (`navigate_locate` / `navigate_expand`). No external RAG service can match this architecture because it requires executing inside the database's query optimizer.

**Retrieval benchmark position (v0.9.5, bge-m3 1024d):**
- LoCoMo session recall@10 = 0.8409 (paper-canonical, +4.15pp vs v0.3.x baseline)
- LongMemEval-S recall@10 = 0.9604 (RRF Fix-A v0.6.2, sparse-safe; gap to BM25
  baseline narrowed from −5pp to −2.2pp, p=0.017)

---

## Releases at a glance

| Tag | Theme | Headline gate | Target ship |
|---|---|---|---|
| **v0.3.1** | Hygiene + documentation + bench-gate in CI | All issues closed; gate file mechanism live; no recall change | 2026-05-13 (✅ SHIPPED) |
| **v0.4.0** | Hybrid retrieval promoted to default | LoCoMo session recall@10 +4.15pp (p<0.05); LongMemEval neutral | 2026-05-15 (✅ SHIPPED) |
| **v0.4.1** | **Production hardening** (per first external production-user feedback, 2026-05-16) | R1, R2 docs, R3, R4, R7 from production-user requirements; bench recall@10 gate maintained | 2026-05-17 (✅ SHIPPED) |
| **v0.5.0** | Graph helpers + temporal tuning | `add_edge()`, `temporal_boost` GUC, `max_query_text_chars`, bitemporality columns, `pgmnemo-mcp` package | 2026-05-17 (✅ SHIPPED) |
| **v0.5.1** | Correctness fixes | MCP write path via `ingest()` SP; `temporal_boost` comment corrected | 2026-05-18 (✅ SHIPPED) |
| **v0.5.2** | MCP wheel fix + CI gate | `pgmnemo-mcp` empty wheel fix ([#32](https://github.com/pgmnemo/pgmnemo/issues/32)), `packaging-smoke` CI, docs rollback/calibration | 2026-05-22 (✅ SHIPPED) |
| **v0.6.0** | Adoption tooling (Mem0/AWS, MCP wrapper) | 2026-05-23 (✅ SHIPPED) — RRF Fix-A attempt rolled back (`-22.44 pp` regression confirmed); `as_of_ts` deferred together |
| **v0.6.1** | `as_of_ts` (F2) + stress test fixtures (F3) | 2026-05-23 (✅ SHIPPED) — F1 RRF Fix-A A-scale variant benchmarked, regressed; F1 deferred to v0.6.2 with real-DB evidence in `benchmarks/longmemeval/results/v0.6.1_realdb_20260523/` |
| **v0.6.2** | RRF Fix-A — sparse-safe (Cormack 2009) | 2026-05-24 (✅ SHIPPED) — `recall@10: 0.9491 → 0.9604 (+1.13 pp, p=0.017)` on LongMemEval-S N=500 bge-m3 1024d; resolves v0.6.0/v0.6.1 RRF deferral |
| **v0.6.3** | `recall_lessons` / `recall_hybrid` AmbiguousColumn hotfix (R1) + R2-R4 USAGE.md docs | 2026-05-24 (✅ SHIPPED) — unblocks production recall; `#variable_conflict use_column` directive, no signature change |
| **v0.7.0** | Outcome-learning loop | `reinforce()` SP, `confidence` column, `match_confidence` in `recall_hybrid()` output, `stats()` confidence distribution | 2026-05-31 (✅ SHIPPED) |
| **v0.7.1** | `match_confidence` calibration fix + batch reinforce | BUG-1: `match_confidence` uses `vec_score` (cosine) not `final_score/1.5`; `reinforce(BIGINT[], TEXT)` batch overload | 2026-06-01 (✅ SHIPPED) |
| **v0.7.2** | Packaging fix | Clean-room install gate in CI; dist structure corrected (no schema change) | 2026-06-01 (✅ SHIPPED) |
| **v0.8.0** | Token-economy navigation + maintenance primitives | `navigate_locate()`, `navigate_expand()`, `reembed()`, `reembed_batch()`, `recompute_content()`, `source_type` + `embedding_at` columns | 2026-06-03 (✅ SHIPPED) |
| **v0.8.1** | Docs sprint | `AGENTS.md` integration guide; README/POSITIONING reframe; ROADMAP public-safe rewrite | 2026-06-03 (✅ SHIPPED) |
| **v0.8.2** | Bug-fix maintenance | `traverse_temporal_window` include_unverified fix; recall NOTICE on 0-row; docs footgun | 2026-06-05 (✅ SHIPPED) |
| **v0.8.3** | GIN index + flat-install hardening | `lesson_tsv` stored GIN column; flat-install Makefile fix | 2026-06-10 (✅ SHIPPED) |
| **v0.9.0** | Token-economy correctness + recall performance | `navigate_locate` budget fix (~5× IDs/budget); ghost-exclusion fix; `recall_hybrid` O(n)→O(k log n); `content_type`/`blob_ref`/`doc_ref` columns | 2026-06-10 (✅ SHIPPED) |
| **v0.9.1** | P0 graph traversal fix | `navigate_expand`/`navigate_locate` traverse all edge kinds (was causal+temporal only); bidirectional BFS; `relation_types` filter; threshold 0.7→0.5 | 2026-06-14 (✅ SHIPPED) |
| **v0.9.2** | Opt-in confidence-weighted ranking GUC | `pgmnemo.confidence_boost_weight` (default `0.0`, off); additive tie-breaker in `recall_hybrid` | 2026-06-17 (✅ SHIPPED) |
| **v0.9.3** | Base-rate-adjusted reinforce() defaults + GUC control | Success delta +0.10→+0.02, failure −0.15→−0.12; `reinforce_success_delta`/`reinforce_fail_delta` GUCs | 2026-06-19 (✅ SHIPPED) |
| **v0.9.4** | Documentation-only | `SQL_REFERENCE.md` + `USAGE.md` coverage for 0.9.2–0.9.3 GUCs; no SQL changes | 2026-06-19 (✅ SHIPPED) |
| **v0.9.5** | Recall-recency signals + corpus curation | `last_recalled_at`, `recall_count` columns; `mark_stale()` with dry-run + safeguards; `track_recall_recency` GUC | 2026-06-19 (✅ SHIPPED) |
| **v0.9.6** | Community response + R11/R12/R13 plumbing | `item_kind`/`version_n`/`patch_count`; `source_dag_id` + `exclude_dag_id`; `memory_ingest_log` table | 2026-06-19 (✅ SHIPPED) |
| **v0.9.7** | MCP params exposure + smoke-test validation | `pgmnemo.get_params` MCP tool; 7-test smoke suite; `pgmnemo_mcp` v0.9.7; no schema changes | 2026-06-20 (✅ SHIPPED) |
| **v0.9.8** | Tiered-memory dispatch + `recall_fast()` + MCP fast-by-default | `navigate_locate_dispatch`, `navigate_expand_typed`, `apply_selective_embedding_policy`, `recall_fast()`; MCP `deep` param; closes #81 | 2026-06-20 (✅ SHIPPED) |
| **v0.10.0** | Extraction substrate + outcome-confidence deepening | `pgmnemo-client` SDK; `ingest_document()` ($0 path + opt-in LLM extraction); `confidence_boost_weight` adoption guide | 2026-06-20 (✅ SHIPPED) |
| **v1.0** | API freeze + stability commitment | 2 consecutive non-breaking releases; stable API contract; outcome-confidence retrieval as headline positioning | 2026-Q4 |

---

## v0.3.1 — Hygiene foundation (✅ SHIPPED 2026-05-13)

**Theme:** close the gaps that block credibility, not the gaps that move recall.

- All open issues closed
- `docs/BENCHMARK_PROTOCOL.md` + `METRICS_BY_VERSION.md` published
- `docs/SQL_REFERENCE.md` created
- CI bench-gate: blocking step runs significance test against `benchmarks/gate/v<version>.json`; missing file = fail
- No recall-algorithm change. No new SQL functions.

---

## v0.4.0 — Hybrid retrieval default (✅ SHIPPED 2026-05-15)

**Theme:** promote `recall_hybrid()` to the default recall path with real-DB bench confirmation.

- `recall_hybrid()` becomes the default in `recall_lessons()` when `query_text` is provided
- Opt-out: `SET pgmnemo.disable_hybrid = 'true'` restores vector-only behaviour
- LoCoMo session recall@10: 0.7951 → 0.8409 (+4.58pp, p=0.0156). LongMemEval-S: no regression.

---

## v0.4.1 — Production hardening (✅ SHIPPED 2026-05-17)

**Theme:** ship what the first external production adopter asked for.

- `pgmnemo.stats()`: one-row diagnostic SP (version, lesson_count, coverage, GUC values, orphan_count)
- Diagnostic columns appended to `recall_lessons()`: `vec_score`, `bm25_score`, `rrf_score`
- `docs/INSTALL.md`: 4-path install guide (PGXN, Docker, GitHub zip, native)
- GUC defaults from ablation study: `recency_weight=0.05`, `ef_search=100`, `importance_weight=0.15`
- `MIGRATION.md §B.5`: detect + recover from extension-orphan functions blocking upgrades

---

## v0.5.0 — Graph helpers + temporal tuning (✅ SHIPPED 2026-05-17)

- `pgmnemo.add_edge()`: idempotent edge writer with `edge_kind` auto-derived from `relation_type`
- `pgmnemo.temporal_boost` GUC: multiplier on recency component for timestamp-sensitive workloads
- `pgmnemo.max_query_text_chars` GUC: input-length guard for `ingest()` and recall `query_text`
- Bitemporality columns: `t_valid_from`, `t_valid_to`, `content_hash` on `agent_lesson`
- `pgmnemo-mcp` Python package: MCP server wrapping `ingest()` and `recall_lessons()`
- 4-arg `traverse_causal_chain()` removed (deprecated in v0.4.1 with NOTICE)
- `mem_edge` columns renamed: `lesson_a_id` → `source_id`, `lesson_b_id` → `target_id`

---

## v0.5.1 — MCP write path (✅ SHIPPED 2026-05-18)

- MCP server `ingest()` path honours provenance gate
- `temporal_boost` comment corrected in SQL

---

## v0.5.2 — MCP packaging fix (✅ SHIPPED 2026-05-22)

- Empty wheel fix for `pip install pgmnemo-mcp`
- `packaging-smoke` CI gate added
- `docs/MIGRATION.md` rollback procedure (v0.5→v0.4)

---

## v0.6.0 — Adoption observability (✅ SHIPPED 2026-05-23)

- `stats().ghost_count`: active lessons with `verified_at IS NULL` (provenance debt)
- `RAISE NOTICE` on content-hash dedup in `ingest()`
- `pgmnemo.recall_stats` view: call counts + timing from `pg_stat_user_functions`

---

## v0.6.1 — Bitemporal recall (✅ SHIPPED 2026-05-23)

- `recall_lessons(as_of_ts TIMESTAMPTZ)`: 6th param for point-in-time recall
- Propagates to `recall_hybrid()` via `pgmnemo.as_of_timestamp` GUC (transaction-local; cleared on COMMIT/ROLLBACK)
- `stress_recall` pg_regress fixture

---

## v0.6.2 — RRF Fix-A (✅ SHIPPED 2026-05-24)

Sparse-safe Reciprocal Rank Fusion (Cormack 2009). Unmatched candidates get
`n_candidates + 1` rank (null-safe) instead of a fixed fallback.

**Result on LongMemEval-S N=500 bge-m3:** recall@10 0.9491 → **0.9604** (+1.13pp, p=0.017).

---

## v0.6.3 — AmbiguousColumn hotfix (✅ SHIPPED 2026-05-24)

- `#variable_conflict use_column` added to `recall_lessons()` and `recall_hybrid()`
- Fixes `psycopg2.errors.AmbiguousColumn` causing 0% hit rate on affected deployments
- No scoring change, no signature change

---

## v0.7.0 — Outcome-learning loop (✅ SHIPPED 2026-05-31)

Lessons now carry a `confidence REAL DEFAULT 0.5` field that responds to observed outcomes.

- `pgmnemo.reinforce(lesson_id, outcome)`: `'success'` +0.10 / `'failure'` −0.15 / `'neutral'` no-op
- `recall_hybrid()` includes `confidence` in aux scoring and returns `match_confidence REAL [0,1]`
- `stats()` gains confidence distribution: `confidence_mean`, `confidence_p10/p50/p90`, `confidence_below_threshold_count`
- New columns: `confidence`, `success_count`, `fail_count`, `last_outcome`, `last_outcome_at`

---

## v0.7.1 — BUG-1 fix + batch reinforce (✅ SHIPPED 2026-06-01)

- **BUG-1:** `match_confidence` now uses `vec_score` (cosine [0,1]) — was `final_score/1.5` (RRF-scale ~0.005). Values are now interpretable.
- `reinforce(BIGINT[], TEXT)` batch overload: process multiple lessons; skips missing IDs silently

⚠️ v0.7.1 dist zip had a packaging error. Use v0.7.2.

---

## v0.7.2 — Packaging fix (✅ SHIPPED 2026-06-01)

- Correct dist structure (double-nested `extension/extension/` removed)
- CI clean-room install gate: installs zip into a pristine `pgvector/pgvector:pg17` container before any publish
- No schema changes — SQL identical to v0.7.1

---

## v0.8.0 — Token-economy navigation (✅ SHIPPED 2026-06-03)

**Theme:** locate relevant memories cheaply; expand content only for what you need.

### New functions

| Function | Purpose |
|---|---|
| `navigate_locate(embedding, text, budget_chars, jsonb_filter)` | Returns ranked IDs + 50-char previews within a cumulative char budget. JSONB filter pushed to GIN index. |
| `navigate_expand(ids, expand_fields, graph_depth, weight_threshold)` | Fetches full `lesson_text` + JSONB field projection + graph neighbors for caller-chosen IDs. |
| `reembed(lesson_id, new_vector)` | Single-row embedding refresh (UPDATE-only; no new bitemporal row; updates `embedding_at`). |
| `reembed_batch(lesson_ids[], new_vectors[])` | Batch embedding refresh with `FOR UPDATE SKIP LOCKED`. Returns count updated. |
| `recompute_content(lesson_id, new_text)` | In-place `lesson_text` update; cascades `content_hash`, `lesson_tsv`, `updated_at` automatically. |

### New columns on `agent_lesson`

| Column | Type | Default | Purpose |
|---|---|---|---|
| `source_type` | `TEXT CHECK(...)` | `'auto_captured'` | Origin classification: `agent_authored` \| `auto_captured` \| `imported` \| `system` |
| `embedding_at` | `TIMESTAMPTZ` | `NULL` | Timestamp of last `reembed()` / `reembed_batch()` call |

---

## v0.8.1 — Docs sprint (✅ SHIPPED 2026-06-03)

- `AGENTS.md`: canonical single-file agent integration guide with all functions and working SQL
- `README.md`, `POSITIONING.md`, `docs/WHY_PGMNEMO.md`: reframed to single-plan multimodal fusion; version badges updated to 0.8.1; benchmark numbers corrected to 0.9604
- `ROADMAP.md`: public-safe rewrite; internal strategy language removed; all shipped versions marked
- `docs/SQL_REFERENCE.md`, `docs/USAGE.md`: v0.8.0 coverage (planned follow-on)

---

## v0.8.2 — Bug-fix maintenance (✅ SHIPPED 2026-06-05)

- `traverse_temporal_window()`: `include_unverified` parameter now respected (was silently ignored)
- `recall_hybrid()` / `recall_lessons()`: `RAISE NOTICE` when 0 rows returned — aids debugging silent misses
- `docs/USAGE.md`: corrected a footgun in the provenance-gate examples that suggested `gate_strict=on` was safe to set globally

---

## v0.8.3 — GIN index + flat-install hardening (✅ SHIPPED 2026-06-10)

- `lesson_tsv TSVECTOR GENERATED ALWAYS AS (...) STORED`: pre-computed full-text search vector with a GIN index; BM25 path no longer re-computes `to_tsvector()` at query time
- Flat-install `Makefile` fix: `pgmnemo--<version>.sql` now correctly emitted by the build pipeline; earlier versions could produce a silently empty SQL file on some platforms

---

## v0.9.0 — Token-economy correctness + recall performance (✅ SHIPPED 2026-06-10)

**Theme:** fix `navigate_locate` budget accounting and tighten the recall hot path.

- **`navigate_locate` budget fix:** cumulative char counter was over-counting by a factor of ~5 (tracked compressed row bytes rather than `length(lesson_text)`). After fix, the same `token_budget_chars` returns ~5× more IDs. ⚠️ Callers with tight budgets may need to adjust.
- **Ghost-exclusion fix:** lessons with `state = 'deprecated'` were leaking into recall results via the BM25 path; excluded at the `WHERE is_active` gate now applied uniformly across all three scoring paths
- **`recall_hybrid()` O(n) → O(k log n):** vector candidate set now uses an HNSW `<=>` index scan with `ef_search` limit instead of a full sequential scan + sort
- **New columns on `agent_lesson`:** `content_type TEXT`, `blob_ref TEXT`, `doc_ref TEXT` — structured pointers to source content; all nullable, no schema migration required for existing rows

---

## v0.9.1 — P0 graph traversal fix (✅ SHIPPED 2026-06-14)

- `navigate_expand()` and `navigate_locate()` now traverse **all** `edge_kind` values (was restricted to `causal` + `temporal` only; `similarity`, `semantic`, and custom kinds were silently ignored)
- **Bidirectional BFS:** graph traversal now follows edges in both directions (`source_id → target_id` and `target_id → source_id`)
- **`relation_types TEXT[]` filter param** added to `navigate_expand()` — callers can restrict traversal to a named subset of relation types (e.g. `ARRAY['causal','supersedes']`)
- **Edge weight threshold** lowered from 0.7 → 0.5 — allows weaker-signal edges to participate in expansion without being pruned

---

## v0.9.2 — Confidence-weighted ranking GUC (✅ SHIPPED 2026-06-17)

*(No separate tag — shipped as part of v0.9.3)*

- **`pgmnemo.confidence_boost_weight` GUC** (DOUBLE PRECISION, default `0.0`, off): when set > 0, adds `w × (confidence − 0.5)` to the final RRF score — zero-centered so neutral-confidence lessons (0.5) get no boost or penalty
- Default `0.0` keeps behaviour identical to v0.9.1 for all existing deployments
- Activate per-session: `SET pgmnemo.confidence_boost_weight = '0.3';`

---

## v0.9.3 — Base-rate-adjusted reinforce() defaults (✅ SHIPPED 2026-06-19)

- **Recalibrated deltas:** success `+0.10` → `+0.02`; failure `−0.15` → `−0.12`. Previous defaults caused confidence to saturate at the ceiling under typical success rates, destroying discriminability.
- **`reinforce_success_delta` / `reinforce_fail_delta` GUCs**: both DOUBLE PRECISION, clamped `[0.001, 0.5]`. Override per-session or at DB/role level.
- Both scalar `reinforce(BIGINT, TEXT)` and batch `reinforce(BIGINT[], TEXT)` forms updated.

---

## v0.9.4 — Documentation-only release (✅ SHIPPED 2026-06-19)

No SQL changes. Schema identical to v0.9.3.

- `docs/SQL_REFERENCE.md`: added `confidence_boost_weight` to §3.1; new §3.3 Outcome-learning GUCs covering `reinforce_success_delta` and `reinforce_fail_delta`; §3.6 default-change history updated
- `docs/USAGE.md`: `reinforce()` section updated to reflect new default deltas; GUC override example added

---

## v0.9.5 — Recall-recency signals + corpus curation (✅ SHIPPED 2026-06-19)

**Theme:** a 6,500+ lesson corpus where 92% had never been recalled was uncuratable by use. This release adds the usage signal and a safe curation primitive.

### New columns on `agent_lesson`

| Column | Type | Default | Purpose |
|---|---|---|---|
| `last_recalled_at` | `TIMESTAMPTZ` | `NULL` | Stamped by all four recall functions on every call. NULL = never recalled since v0.9.5. |
| `recall_count` | `BIGINT` | `0` | Incremented once per recall-function call that returns this lesson. Monotonically increasing. |

### New function

**`pgmnemo.mark_stale(p_unused_days, p_min_confidence_keep, p_keep_provenance, p_dry_run, p_cap)`**

Identifies and optionally deprecates lessons unused for `p_unused_days` (default 45). Built-in safeguards: does not touch lessons with `confidence >= p_min_confidence_keep` (default 0.6), `importance = 5`, or a `commit_sha` (provenance bearing). `p_dry_run=TRUE` (default) is fully read-only. `p_cap` (default 500) refuses to act if candidate count exceeds the cap — requires explicit acknowledgement.

### Other changes

- **GUC `pgmnemo.track_recall_recency`** (BOOLEAN, default `on`): set to `off` to suppress stamping globally, e.g. during bulk testing or replay.
- `recall_hybrid()`, `recall_lessons()`, `navigate_locate()`, `navigate_expand()` changed from `STABLE` → `VOLATILE` (required for the UPDATE side-effect in the stamp CTE). No scoring change.
- **Partial index** `ix_pgmnemo_lesson_recall_recency` on `(last_recalled_at ASC NULLS FIRST, created_at ASC) WHERE is_active` — supports efficient stale-lesson scans.

---

## v0.9.6 — Community response + R11/R12/R13 plumbing (Planned)

**Theme:** close the remaining agency-requirement gaps from [Issue #31](https://github.com/pgmnemo/pgmnemo/issues/31) and respond to reviewer feedback before the extraction substrate build begins.

### New columns on `agent_lesson`

| Column | Type | Default | Purpose |
|---|---|---|---|
| `item_kind` | `TEXT CHECK(...)` | `'note'` | Item type: `note` \| `skill_md` \| `template` \| `script` \| `reference` \| `config` \| `spec`. Default preserves all existing rows. |
| `version_n` | `INT` | `1` | Version number for skill items. Operator-managed. |
| `patch_count` | `INT` | `0` | Count of in-place patches since last full rewrite. Operator-managed. |
| `source_dag_id` | `TEXT NULL` | `NULL` | DAG / workflow ID that produced this lesson. Used with `exclude_dag_id` to prevent self-referential recall loops. |

### New table

**`pgmnemo.memory_ingest_log`** — provenance metadata for migration batches. Keeps `agent_lesson` lean on the hot path; drop the table when the cutover window closes.

```sql
CREATE TABLE pgmnemo.memory_ingest_log (
    id            BIGSERIAL PRIMARY KEY,
    source_origin TEXT NOT NULL,
    min_id        BIGINT,
    max_id        BIGINT,
    ingested_at   TIMESTAMPTZ DEFAULT NOW(),
    retired_at    TIMESTAMPTZ NULL
);
```

### Recall function addition

`exclude_dag_id TEXT DEFAULT NULL` parameter added to `recall_hybrid()` and `recall_lessons()`: when set, excludes all lessons where `source_dag_id = exclude_dag_id`. Prevents a running DAG from recalling its own in-flight outputs.

### Docs

- `docs/MIGRATION.md`: worked example for folding a legacy memory table into `pgmnemo.agent_lesson` using `memory_ingest_log` for provenance tracking and a dual-read deprecation window
- `ROADMAP.md`: this file

---

## v0.10.0 — Extraction substrate (✅ SHIPPED 2026-06-20)

**Theme:** first substrate feature — turn text into a queryable knowledge graph automatically. Without auto-extraction the graph layer is empty and graph-augmented retrieval is hollow.

**Priority rationale (P1):** closes S1 of the causal positioning chain (structured lesson capture); without `ingest_document()` adopters must hand-author every lesson, which blocks cold-start. `confidence_boost_weight` adoption guide also ships here — `reinforce()` is live since v0.7.0 but most adopters leave the GUC at default `0.0` and miss the ranking benefit.

### Extraction pipeline

`ingest_document(source TEXT, source_type TEXT DEFAULT 'text')`: accepts raw text, Markdown, or a local file path. Internally: chunk → embed → ingest into `agent_lesson`, then LLM (Haiku) entity + relation extraction → typed edges via `add_edge()`. Cost ≈ Haiku $/document. Logged to `memory_ingest_log`.

### Python client SDK

`pip install pgmnemo-client` — thin wrapper over the SQL API. Three-line quickstart:

```python
import pgmnemo
mem = pgmnemo.connect("postgresql://...")
mem.ingest("Claude solved the N+1 query by adding select_related()")
results = mem.recall("database query optimization", top_k=5)
```

Covers: `connect()`, `ingest()`, `ingest_document()`, `recall()`, `reinforce()`.

---

## v1.0 — Stability commitment (Planned)

**Theme:** API freeze; officially production-ready.

**Criteria (all must be true):**

- 2 consecutive releases with no breaking SQL function signature changes
- Every public SQL function documented in `SQL_REFERENCE.md` with a worked example in `USAGE.md`
- LongMemEval-S recall@10 no regression vs v0.9.6 baseline (CI bench-gate enforces this; active improvement sprints are deprioritized)
- LoCoMo session recall@10 held vs v0.8.0 baseline
- Rollback procedure validated end-to-end at least once

**What v1.0 does NOT promise:**
- Cloud-hosted SaaS — pgmnemo is an extension, not a service
- Compatibility with non-Postgres backends
- Scale beyond 10M rows (dedicated vector DBs own billion-row)

---

## What is NOT on this roadmap

| Idea | Status | Reason |
|---|---|---|
| Configurable vector dimension (non-1024) | Backlog | No adopter request; `vector(1024)` covers current MTEB-competitive models |
| REST API wrapper | Out of scope | Extension, not a service |
| Cloud-hosted SaaS | Out of scope | Self-hosted is the product |
| Billion-row scale | Out of scope | Target range is 10k–10M; dedicated vector DBs own billion-row |
| `recency_weight` GUC tuning / ablation | **Deprioritized (P3)** | Not in the causal positioning chain; optimising it argues against our own story. GUC remains as-is for compatibility; no new improvement investment. |
| Benchmark improvement sprints (LoCoMo / LongMemEval marginal gains) | **Deprioritized (P3)** | CI bench-gate enforces no-regression. Active sprint goals chasing +pp numbers add cost without advancing the causal argument. New academic comparisons (DRAGON, retrieval suites) deferred to post-v1.0 research track. |

---

## Bench gate policy

Every release tag requires:

1. A passing significance test against `benchmarks/gate/v<version>.json`
2. A new row in `benchmarks/METRICS_BY_VERSION.md`
3. A `CHANGELOG.md` entry in user-readable language

If the bench gate fails, **the tag is not pushed.**
