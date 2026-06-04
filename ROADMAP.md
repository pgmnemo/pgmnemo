# pgmnemo Roadmap

**Effective:** 2026-06-04

---

## Strategic frame

pgmnemo is the **single-plan multimodal memory layer** for AI agent developers
who already run Postgres. Install in under 5 minutes; replace ad-hoc memory
code with two SQL calls. No new service. No data egress. EXPLAIN-able ranking.

**Current moat:** Vector + BM25 + graph proximity + JSONB predicate pushdown in one
SQL query plan — plus provenance-gated writes and token-economy navigation
(`navigate_locate` / `navigate_expand`). No external RAG service can match this
architecture because it requires executing inside the database's query optimizer.

**Retrieval benchmark position (v0.8.0):**
- LoCoMo session recall@10 = 0.8409 (paper-canonical, +4.15pp vs v0.3.x)
- LongMemEval-S recall@10 = 0.9604 (hybrid RRF Fix-A v0.6.2, gap to BM25 baseline
  narrowed from −5pp to −2.2pp, p=0.017)

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
| **v1.0** | API freeze + stability commitment | 2 consecutive non-breaking releases; stable API contract | 2026-Q4 |

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

## v0.8.1 — Docs sprint (🔄 IN PROGRESS)

- `AGENTS.md`: canonical single-file agent integration guide with all functions and working SQL
- `README.md`, `POSITIONING.md`, `docs/WHY_PGMNEMO.md`: reframed to single-plan multimodal fusion; version badges updated to 0.8.1; benchmark numbers corrected to 0.9604
- `ROADMAP.md`: public-safe rewrite; internal strategy language removed; all shipped versions marked
- `docs/SQL_REFERENCE.md`, `docs/USAGE.md`: v0.8.0 coverage (planned follow-on)

---

## v1.0 — Stability commitment (Planned)

**Theme:** API freeze; officially production-ready.

**Criteria (all must be true):**

- 2 consecutive releases with no breaking SQL function signature changes
- Every public SQL function documented in `SQL_REFERENCE.md` with a worked example in `USAGE.md`
- LongMemEval-S recall@10 ≥ 0.97 (p < 0.05)
- LoCoMo session recall@10 held or improved vs v0.8.0 baseline
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

---

## Bench gate policy

Every release tag requires:

1. A passing significance test against `benchmarks/gate/v<version>.json`
2. A new row in `benchmarks/METRICS_BY_VERSION.md`
3. A `CHANGELOG.md` entry in user-readable language

If the bench gate fails, **the tag is not pushed.**
