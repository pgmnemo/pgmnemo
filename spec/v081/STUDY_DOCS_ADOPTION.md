# STUDY: pgmnemo 0.8.1 Docs Sprint — Phase 1
**Task:** PGMDOC-260604-STUDY  
**Date:** 2026-06-04  
**Status:** WORKING DOCUMENT (gitignored, internal)  
**Purpose:** Ground WRITE-AGENTS + FIX-POSITIONING for the 0.8.1 docs sprint.

---

## Part A — Doc Drift Audit

### A1. README.md

| Location | Issue | Severity |
|---|---|---|
| Version badge (line 7) | `version-0.7.2` badge, `0.7.2` in all download URLs, `pgxn install pgmnemo==0.7.2` | 🔴 P0 — wrong version everywhere |
| Compatibility matrix (line 79) | Shows `0.5.x (current)` — three major versions behind | 🔴 P0 |
| "What's next" blurb (line 31) | Says "v0.7 outcome-learning loop (reinforcement-from-outcome recall weighting)" — v0.7.x shipped | 🔴 P0 |
| Benchmark intro (line 33) | Labeled "v0.5.1, retrieval-only" — outdated epoch | 🔴 P0 |
| Features section (lines 161–167) | No mention of v0.8.0 capabilities: `navigate_locate`, `navigate_expand`, `reembed`, `reembed_batch`, `recompute_content`, `source_type`, `embedding_at` | 🔴 P0 |
| Features section (lines 161–167) | No mention of v0.7.x capabilities: `reinforce()`, `confidence`, `match_confidence` | 🔴 P0 |
| Why-this-exists (line 62–64) | Differentiator framed as provenance gate only; omits single-plan multimodal fusion, EXPLAIN-able ranking, zero-egress, ACID writes | 🟠 P1 |
| No token-economy pattern | `navigate_locate` + `navigate_expand` "locate cheaply, expand only what you need" not described | 🟠 P1 |
| No graph-proximity calibration mention | `pgmnemo.graph_proximity_weight` GUC + calibration story absent from features | 🟡 P2 |
| Benchmark table (lines 42–48) | LoCoMo/LongMemEval rows frozen at 0.5.x-era numbers (LME 0.9334, LoCoMo 0.8409); v0.6.2 pushed LME to 0.9604 | 🟠 P1 |
| Docker quickstart (lines 117–134) | Uses `v0.7.2` release URL — must be updated to `v0.8.0` (or `v0.8.1` when tagged) | 🔴 P0 |
| Competitor comparison table (line 69–73) | Framed around "provenance enforcement / zero data egress / install model / self-hosted price" — misses graph-proximity + JSONB pushdown + EXPLAIN-able plan as differentiator axes | 🟠 P1 |

### A2. POSITIONING.md

| Location | Issue | Severity |
|---|---|---|
| Tagline/header | "hybrid recall, zero-cost writes, optional provenance enforcement" — accurate but undersells the single-plan fusion story | 🟠 P1 |
| Differentiator claim (line 59) | Says "only Postgres extension that combines hybrid in-database recall (vectors + BM25) with optional write-time compliance enforcement" — TRUE but incompletely stated. Missing: graph proximity + JSONB predicate pushdown + relational, all in one SQL plan. | 🟠 P1 |
| Competitor matrix — Recall substrate (line 68) | pgmnemo cell says "HNSW vectors + BM25 full-text + recency + graph proximity, all in SQL" — accurate but omits JSONB pushdown and the one-query-plan framing | 🟡 P2 |
| Benchmark table (line 153–156) | LME 0.9334 still listed; v0.6.2 measured 0.9604 (+1.13pp, p=0.017); production corpus row is stale (v0.4.1 era) | 🟠 P1 |
| No v0.8.0 token-economy navigation | `navigate_locate` + `navigate_expand` not mentioned anywhere in competitor comparison or decision framework | 🟠 P1 |
| No outcome-learning mention | `reinforce()` / `confidence` / `match_confidence` (v0.7.x) absent from capability list | 🟠 P1 |
| "Temporal = Zep" framing risk | Competitor matrix positions Zep as "LLM-driven contradiction detection" and bitemporal as a counter — framing risks conceding temporal as Zep's domain rather than centering our SQL-native as_of recall | 🟡 P2 |
| No EXPLAIN-ability mention | Zero mention that recall ranking is SQL-plan inspectable via EXPLAIN — unique vs every SaaS RAG | 🟠 P1 |
| production user count | Not explicitly stated here but WHY_PGMNEMO.md says "1 (internal)"; POSITIONING.md table says "1 external early-adopter (growing)" — needs honest sync across docs | 🟡 P2 |

### A3. docs/WHY_PGMNEMO.md

| Location | Issue | Severity |
|---|---|---|
| "Honest current state" (line 118) | `Latest release: v0.4.1 (2026-05-17)` — completely wrong; now v0.8.0 (2026-06-03) | 🔴 P0 |
| Benchmark numbers in honest-state (line 120) | LoCoMo 0.84, LME 0.93; both stale + "loses to BM25 baseline 0.98" — fixed in v0.6.2 (0.9604, gap narrowed; now 0.982−0.9604 = 2.16pp) | 🔴 P0 |
| Dockerfile example (line 78) | Uses `v0.4.1` URLs — three major versions outdated | 🔴 P0 |
| "What you get" list (lines 26–45) | Lists provenance gate, hybrid retrieval, multi-tenant RLS, Apache-2.0 — no mention of navigate_locate/expand, outcome-learning, reembed, source_type, bitemporal as_of | 🟠 P1 |
| "Don't choose us if" (lines 65–68) | "entity-relation-temporal reasoning over months of history → use Zep" — concedes temporal as Zep-only. Our `as_of_ts` bitemporal point-in-time recall and mem_edge temporal edges cover this partially now. | 🟡 P2 |
| No single-plan multimodal fusion | The differentiating architecture claim (one SQL plan spanning vector + graph + JSONB + relational) is entirely absent | 🔴 P0 (positioning gap) |
| "Open issues: 10" (line 122) | Stale count from v0.4.1 era | 🟡 P2 |

### A4. ROADMAP.md

| Location | Issue | Severity |
|---|---|---|
| "Workflow rules: see core-team workflow" (line 4) | Internal reference that should be redacted or removed from public doc | 🟠 P1 |
| "wedge customer (the team positioning (internal))" (line 15) | Explicit internal reference leak in a public document | 🟠 P1 |
| Releases table (line 51) | v0.7.0 listed as "2026-09 (conditional)"; v0.7.0, 0.7.1, 0.7.2 all shipped; v0.8.0 not in table | 🔴 P0 |
| WG-STRAT-260517 reference (line 26) | Internal working-group identifier in a public document | 🟠 P1 |
| T1/T2/T3 threat posture (lines 28–32) | "3-day research spike", "Monitor `getzep/graphiti` PRs", "T3 — Letta Aurora in production" — internal strategy language inappropriate for public doc | 🔴 P0 |
| MAGMA references throughout | MAGMA is an internal research-program name; it appears as edge_kind "MAGMA §3" in SQL COMMENTS (acceptable) but appears as strategy framing in ROADMAP which is a public doc | 🟡 P2 |
| v1.0 gate: "≥ 3 external adopters with public case studies" (line 52) | Exposing internal adoption-count gate | 🟡 P2 |
| Hypothesis declarations (lines 99–108) | "ICE: I=10 C=8 E=6 (highest in backlog)" — internal scoring framework that reads as jargon | 🟡 P2 |

### A5. docs/USAGE.md

| Location | Issue | Severity |
|---|---|---|
| `recall_lessons()` signature (line 70–93) | Missing `as_of_ts` 6th param (shipped v0.6.1); scoring formula on line 97 shows old pre-Fix-A formula | 🔴 P0 |
| Scoring formula (line 98–103) | Shows `0.5×cosine + 0.2×importance + γ×recency + 0.1×prov_strength` — this is the **vector-only** path; hybrid (Fix-A v0.6.2 RRF) not shown | 🟠 P1 |
| No navigate_locate/expand section | v0.8.0 token-economy navigation API completely absent | 🔴 P0 |
| No reembed/reembed_batch/recompute_content section | v0.8.0 maintenance primitives absent | 🔴 P0 |
| No reinforce() / outcome-learning section | v0.7.x shipped; not documented in USAGE.md | 🔴 P0 |
| No source_type documentation | New column with controlled vocabulary ('agent_authored'|'auto_captured'|'imported'|'system'); absent | 🟠 P1 |
| No embedding_at documentation | Tracks when embedding was last refreshed; absent | 🟡 P2 |

### A6. docs/SQL_REFERENCE.md

| Location | Issue | Severity |
|---|---|---|
| Header (line 3) | "Version coverage: v0.6.0 (current)" — two major versions stale (now v0.8.0) | 🔴 P0 |
| `agent_lesson` schema (line 24–46) | Column `id` listed as `lesson_id` (incorrect — table uses `id` as column; `lesson_id` is only the output alias in `recall_lessons()`) | 🟠 P1 |
| `agent_lesson` schema | Missing `source_type TEXT CHECK(...)` (v0.8.0) | 🔴 P0 |
| `agent_lesson` schema | Missing `embedding_at TIMESTAMPTZ` (v0.8.0) | 🔴 P0 |
| `agent_lesson` schema (line 43) | `source_run_id` listed as `BIGINT` — actual schema has it as `TEXT` | 🟠 P1 |
| `agent_lesson` schema (line 37) | `state DEFAULT 'candidate'` — actual schema default is `'draft'` | 🟠 P1 |
| `recall_lessons()` signature (line 236–263) | Shows 6th param `as_of_ts TIMESTAMPTZ` — the **actual 0.8.0 SQL defines only 5 params**; as_of is via GUC `pgmnemo.as_of_timestamp` (set by recall_lessons internally but not an explicit param in the 0.8.0 flat install). Needs verification against final 0.8.0 build. | 🟠 P1 (needs verification) |
| `recall_hybrid()` signature (line 319–344) | Missing new trailing columns: `confidence REAL`, `match_confidence REAL` (added v0.7.1) | 🔴 P0 |
| `navigate_locate()` — ABSENT | Not documented at all; shipped v0.8.0 | 🔴 P0 |
| `navigate_expand()` — ABSENT | Not documented at all; shipped v0.8.0 | 🔴 P0 |
| `reembed()` — ABSENT | Not documented; shipped v0.8.0 | 🔴 P0 |
| `reembed_batch()` — ABSENT | Not documented; shipped v0.8.0 | 🔴 P0 |
| `recompute_content()` — ABSENT | Not documented; shipped v0.8.0 | 🔴 P0 |
| `reinforce(BIGINT, TEXT)` — ABSENT | Not documented; shipped v0.7.0 (single) + v0.7.1 (batch overload BIGINT[]) | 🔴 P0 |
| `stats()` (line 404–427) | Shows 14 columns from v0.6.0; v0.7.0 added 5 confidence-distribution columns (total 19). Exact new cols: `confidence_mean`, `confidence_stddev`, `confidence_above_threshold_count`, `confidence_below_threshold_count` (need to confirm exact names from SQL) | 🟠 P1 |
| GUC section (§3) | No GUC entry for `pgmnemo.as_of_timestamp` (set as session GUC by `recall_lessons()` when `as_of_ts` is passed) | 🟡 P2 |
| GUC section (§3) — recency_weight default | Shows `0.05` (v0.4.1) — correct | ✅ |
| GUC table missing v0.8.0 additions | No new GUCs were added in v0.8.0 (navigate_locate reads existing GUCs: ef_search, include_unverified, as_of_timestamp, graph_proximity_weight) | N/A — no change needed |
| Deprecation log (line 560–566) | Current as of v0.5.0 — should add v0.7.x and v0.8.0 deprecation/addition notes | 🟡 P2 |

---

## Part B — Public-Safe Moat Narrative

### Problem Statement (external, industry terms)

Agent memory systems share a structural defect: retrieval quality degrades as memory grows. The dominant architectural choices — separate vector stores (Pinecone, Weaviate), cloud memory APIs (Mem0, Zep), or ad-hoc `pgvector` tables — each create the same failure cluster:

1. **Scattered stores, split query plans.** Vector retrieval, keyword search, graph edges, and metadata filters live in separate systems or separate queries. The final ranking happens in application code, not in the database optimizer. No single EXPLAIN shows you why a memory was ranked first.

2. **Data egress for ingestion.** Cloud memory APIs send your agent's observations to vendor infrastructure for LLM-powered fact extraction, embedding, or contradiction detection. Every write crosses a trust boundary you do not own, at a cost you cannot predict (~$0.17–$0.36 per 1,000 writes before your own inference budget).

3. **Context-token bloat.** Without budget discipline, retrieval returns everything that scored above a threshold. Large corpora return entire lesson texts. Agents receive 8,000 tokens of memory context and use 200.

4. **Opaque, non-inspectable ranking.** Score = some float. You cannot EXPLAIN the ranking. You cannot regression-test it with SQL. Tuning is guess-and-check.

5. **Hallucinated memory accumulates silently.** No write-path enforcement ensures a memory was derived from a verifiable artifact. Broken agent runs produce plausible-but-wrong memories that survive across all future recall calls.

### pgmnemo's Differentiating Claim

**Single-plan multimodal fusion inside your existing Postgres.**

pgmnemo ranks across four retrieval channels — HNSW vector (pgvector), graph-edge proximity (mem_edge BFS), JSONB metadata predicate pushdown (GIN index), and relational filters (role/project_id/state) — inside a **single SQL query plan**. PostgreSQL's query optimizer manages the join, filter, and sort. The developer calls one function; the database handles the rest.

This architecture produces consequences a separate RAG service cannot replicate:

| Capability | How |
|---|---|
| **Zero data egress** | Embeddings, graph edges, metadata, and ranking all live in your Postgres. No network call leaves your database at retrieval time. |
| **$0 LLM-free ingestion** | `pgmnemo.ingest()` is a SQL constraint check + indexed INSERT. No model API call on the write path. |
| **SQL-inspectable / EXPLAIN-able ranking** | Run `EXPLAIN (ANALYZE, BUFFERS)` on any `recall_lessons()` or `navigate_locate()` call. The full plan is visible. |
| **ACID incremental updates** | `reembed()`, `reembed_batch()`, `recompute_content()` update rows in-place with full ACID guarantees. No re-ingestion pipeline. |
| **Provenance-gated writes** | `pgmnemo.gate_strict = 'enforce'` blocks writes without a `commit_sha` or `artifact_hash` at the Postgres constraint layer — application code cannot bypass it without SUPERUSER. |
| **Outcome-learning** | `reinforce(lesson_id, 'positive')` increments confidence; `reinforce(lesson_id, 'negative')` decrements. `recall_hybrid()` includes `confidence` in scoring and returns `match_confidence` as an interpretable [0,1] signal. |
| **Bitemporal as_of recall** | `recall_lessons(..., as_of_ts := '2026-01-01')` restricts candidates to the validity window `t_valid_from ≤ as_of_ts < t_valid_to`. Time-travel your agent's memory. |
| **Token-economy navigation** | `navigate_locate()` returns IDs within a `token_budget_chars` limit — **locate cheaply, expand only what you need**. `navigate_expand(ids)` fetches content + graph neighbors on demand. |

### What a Separate RAG Service Cannot Match

A RAG service (cloud or self-hosted) that sits outside your database can vector-rank or BM25-rank, but:

- It cannot join your relational data (project_id scoping, role filtering, state machine gates) in the same query plan without a separate service call.
- It cannot push JSONB predicates into a GIN index in the same scan that does the HNSW walk.
- It cannot do BFS graph traversal over typed edges (causal, temporal, semantic, entity) in the same CTE as the vector recall.
- It cannot show you the execution plan for a recall query.
- It cannot enforce write-time provenance at the database constraint layer.

pgmnemo does all of these in one `SELECT`. The optimizer decides the join order. You own the data.

---

## Part C — Capability Inventory (Every User-Facing Function, 0.8.0)

### C1. Write Path

#### `pgmnemo.ingest(p_role, p_project_id, p_topic, p_lesson_text, [p_importance, p_embedding, p_commit_sha, p_artifact_hash, p_metadata]) → BIGINT`
Validated public write API. Returns new `lesson_id`.
- Validates embedding dim (1024 required if provided).
- Sets `verified_at = NOW()` automatically when provenance present.
- Triggers provenance gate (`gate_strict` GUC: `enforce` | `warn` | `off`).
- Fires `trg_agent_lesson_bitemporal_close` on INSERT (closes prior row with same `content_hash`, emits NOTICE).
- **GUC:** `pgmnemo.gate_strict` (default `enforce`), `pgmnemo.max_query_text_chars` (truncates oversized inputs).

#### `pgmnemo.reinforce(p_lesson_id BIGINT, p_outcome TEXT) → REAL`  *(v0.7.0)*
Single-row outcome-learning update. `p_outcome`: `'positive'` | `'negative'` | `'neutral'`. Applies asymmetric confidence adjustment. Returns new confidence value. Row-locked (SELECT FOR UPDATE). Raises on unknown lesson_id or unknown outcome.

#### `pgmnemo.reinforce(p_lesson_ids BIGINT[], p_outcome TEXT) → INT`  *(v0.7.1 batch overload)*
Batch reinforce. Skips missing lesson_ids silently. Returns count updated. Raises on unknown outcome string.

#### `pgmnemo.reembed(p_lesson_id BIGINT, p_new_vector vector(1024)) → void`  *(v0.8.0)*
Single-row embedding refresh (UPDATE-only). Updates `embedding` + `embedding_at`. Does NOT create a new bitemporal row (INSERT-only trigger not fired). Does NOT alter `lesson_text`, `content_hash`, or `full_text` TSV. Raises if lesson not found or not active.

#### `pgmnemo.reembed_batch(p_lesson_ids BIGINT[], p_new_vectors vector[]) → INT`  *(v0.8.0)*
Batch embedding refresh. Arrays must be same length. Uses `FOR UPDATE SKIP LOCKED` — skips rows locked by concurrent ingest/reinforce. Returns count of rows actually updated (< input if rows were skipped). Pass IDs in ascending order to prevent deadlocks.

#### `pgmnemo.recompute_content(p_lesson_id BIGINT, p_new_text TEXT) → void`  *(v0.8.0)*
In-place `lesson_text` update without bitemporal close+create churn. Cascades automatically: `content_hash` (GENERATED ALWAYS AS), `lesson_tsv` (trigger), `updated_at` (trigger). Preserves: `id`, `embedding`, `mem_edges`, provenance, `confidence`, `source_type`. Note: embedding is stale after this call; follow with `reembed()`.

#### `pgmnemo.add_edge(p_source_id, p_target_id, p_relation_type, [p_weight, p_metadata, p_mode]) → void`  *(v0.5.0)*
Idempotent edge writer. Two overloads (5-param and 6-param). `edge_kind` auto-derived from `p_relation_type` via canonical mapping. `p_mode`: `'replace'` | `'max'` | `'avg'`.

#### `pgmnemo.transition_lesson(lesson_id BIGINT, new_state TEXT) → agent_lesson`
Advance a lesson through the state machine. Validates against `agent_lesson_state_transition` table. States: `draft → candidate → validated → canonical → deprecated → superseded → archived`; also `rejected`, `conflicted`. Raises on invalid transition.

#### `pgmnemo.evict_expired_lessons() → INT`
Hard-delete lessons past their `expires_at`. Returns count removed. Safe to call on a schedule.

### C2. Read / Recall Path

#### `pgmnemo.recall_lessons(query_embedding, [k, role_filter, project_id_filter, query_text]) → TABLE`  *(v0.3.0+, updated through v0.8.0)*
Primary hybrid recall. Five params in 0.8.0 flat install (as_of_ts handled internally via `pgmnemo.as_of_timestamp` GUC set per-transaction by the function when passed).

Output columns: `lesson_id, score, role, project_id, topic, lesson_text, importance, metadata, commit_sha, artifact_hash, verified_at, created_at` + diagnostic `vec_score, bm25_score, rrf_score` (v0.4.1+).

**Scoring (vector-only path):**
```
score = 0.4×cosine + 0.2×(importance/5) + γ×recency(90d) + 0.1×prov_strength + δ×graph_proximity
```
**Scoring (hybrid path, Fix-A v0.6.2):**
```
score = (rrf_diag / norm_denom) + aux(importance, recency, prov) + δ×graph_proximity
```
where `rrf_diag = vec_w/(rrf_k+vec_rank) + bm25_w/(rrf_k+bm25_rank)`.

**GUCs consumed:** `pgmnemo.ef_search`, `pgmnemo.include_unverified`, `pgmnemo.recency_weight`, `pgmnemo.graph_proximity_weight`, `pgmnemo.as_of_timestamp` (bitemporal), `pgmnemo.disable_hybrid`.

#### `pgmnemo.recall_hybrid(query_embedding, query_text, [k, role_filter, project_id_filter, vec_weight, bm25_weight, rrf_k]) → TABLE`  *(v0.2.2+, updated v0.7.1)*
Direct hybrid recall (vector + BM25 union with RRF). Output columns include trailing `confidence REAL, match_confidence REAL` (added v0.7.1).  
`match_confidence` = calibrated [0,1] cosine similarity (BUG-1 fix: uses `vec_score` not `final_score/1.5`).

#### `pgmnemo.recall_lessons_pooled(query_embedding, [k, app_id]) → TABLE`
Cross-role pooled recall wrapper. Calls `recall_lessons()` with `role_filter=NULL`.

#### `pgmnemo.navigate_locate(query_embedding, query_text, [token_budget_chars, jsonb_filter]) → TABLE`  *(v0.8.0)*
**Token-economy LOCATE.** Budget-bounded recall returning IDs within cumulative character limit.

Params:
- `query_embedding vector(1024)` — NULL allowed if `query_text` provided (must have at least one).
- `query_text TEXT` — NULL allowed if `query_embedding` provided.
- `token_budget_chars INT DEFAULT 2000` — cumulative char budget; first row always returned.
- `jsonb_filter JSONB DEFAULT NULL` — pushed as `metadata @> jsonb_filter` into candidate scan (uses GIN index).

Output: `id, preview (first 50 chars), score, tokens_consumed (cumulative), navigation_path`.
`navigation_path`: `'jsonb_gate'` when filter applied; `'vector'` when vec_rank ≤ bm25_rank_eff; `'bm25'` otherwise.

Scoring: same RRF+aux+graph formula as `recall_hybrid` v0.6.2 (with sparse-safe RRF + cardinal raw-score blend `_raw_blend_weight`). Graph BFS capped at 2 hops (locate phase; deeper expansion is `navigate_expand`'s job).

**GUCs consumed:** same as `recall_lessons` + `pgmnemo.as_of_timestamp`.

**Pattern:** call `navigate_locate` to get ranked IDs cheaply (no full content transmitted), then call `navigate_expand` for content on the subset you choose.

#### `pgmnemo.navigate_expand(ids BIGINT[], [expand_fields TEXT[], graph_expand_depth INT, graph_expand_threshold FLOAT]) → TABLE`  *(v0.8.0)*
**Token-economy EXPAND.** Fetches full `lesson_text` + optional JSONB field projection + graph neighbors for caller-chosen IDs.

Params:
- `ids BIGINT[]` — IDs from `navigate_locate` or any source.
- `expand_fields TEXT[] DEFAULT '{}'` — keys to project from `metadata` JSONB into `expand_detail` (empty = NULL).
- `graph_expand_depth INT DEFAULT 1` — BFS depth for causal+temporal edge traversal (0 = no expansion).
- `graph_expand_threshold FLOAT DEFAULT 0.7` — minimum edge weight to traverse.

Output: `id, content (full lesson_text), expand_detail (JSONB projection), graph_neighbor_ids BIGINT[], graph_neighbor_previews TEXT[], tokens_consumed INT, navigation_path TEXT`.  
`navigation_path`: `'content'` for requested IDs; `'graph_expand'` for BFS neighbors.  
`tokens_consumed`: cumulative char count across all rows (running sum of `length(lesson_text)`).

#### `pgmnemo.traverse_causal_chain(start_id, [max_depth, relation_types, only_active, direction]) → TABLE`  *(v0.2.0+, canonical since v0.4.1)*
BFS over causal-kind edges. `direction`: `'forward'` | `'backward'` | `'both'`. Cycle guard via path array. Filters `edge_kind = 'causal'` + `relation_type = ANY(relation_types)`.

#### `pgmnemo.traverse_temporal_window(start_lesson_id, [window_interval]) → TABLE`  *(v0.2.0+)*
Co-temporal episode retrieval within `window_interval` of `start_lesson_id.created_at`.

### C3. Maintenance / Diagnostics

#### `pgmnemo.stats() → TABLE`  *(v0.4.1+, updated v0.6.0, v0.7.0)*
One-row diagnostic snapshot. Current columns (v0.8.0, 19 total):
- `version, lesson_count, embedded_count, embedding_coverage_pct, tsv_coverage_pct`
- `mem_edge_count, recency_weight, ef_search, importance_weight`
- `hybrid_enabled, recall_hybrid_available, oldest_lesson_age_days, orphan_count`
- `ghost_count` (v0.6.0: active lessons with `verified_at IS NULL`)
- 5 confidence-distribution columns (v0.7.0): need exact names confirmed from v0.7.0 SQL (verify: `confidence_mean`, `confidence_stddev`, `confidence_above_threshold_count`, `confidence_below_threshold_count`, possibly `reinforced_count`).

#### `pgmnemo.recall_stats` view  *(v0.6.0)*
Surfaces `pg_stat_user_functions` call counts + timing for `recall_lessons()`, `recall_hybrid()`, `ingest()`. Requires `track_functions = 'pl'` or `'all'` in `postgresql.conf`.

#### `pgmnemo.get_temporal_boost() → FLOAT8`  *(v0.5.0)*
Helper: returns current `pgmnemo.temporal_boost` GUC value.

#### `pgmnemo.version() → TEXT`
Returns installed extension version from `pg_catalog.pg_extension`.

### C4. Schema Additions (v0.8.0)

#### `agent_lesson.source_type TEXT CHECK(...) DEFAULT 'auto_captured'`
Controlled vocabulary: `'agent_authored'` | `'auto_captured'` | `'imported'` | `'system'`.

#### `agent_lesson.embedding_at TIMESTAMPTZ`
Timestamp of last embedding refresh via `reembed()` or `reembed_batch()`. NULL for rows embedded before v0.8.0 (backfilled to `updated_at` on upgrade).

### C5. Provenance Gate (Write-Time Enforcement)

Trigger `enforce_provenance_gate` fires BEFORE INSERT on `agent_lesson`. Reads `pgmnemo.gate_strict` GUC:
- `'enforce'` (default): RAISE EXCEPTION — INSERT rejected, transaction aborted.
- `'warn'`: RAISE WARNING — INSERT proceeds, row is a "ghost lesson" (`verified_at IS NULL`, excluded from recall by default).
- `'off'`: no check.

Ghost lessons excluded from `recall_lessons()` unless `SET pgmnemo.include_unverified = 'true'`.

### C6. GUC Inventory (All User-Facing, v0.8.0)

| GUC | Type | Default | Function |
|---|---|---|---|
| `pgmnemo.gate_strict` | TEXT enum | `enforce` | Provenance gate mode: `enforce`\|`warn`\|`off` |
| `pgmnemo.include_unverified` | BOOL | `false` | Include ghost lessons in recall output |
| `pgmnemo.recency_weight` | FLOAT | `0.05` | γ coefficient on 90-day recency decay |
| `pgmnemo.temporal_boost` | FLOAT | `1.0` | Multiplier on recency: effective_γ = recency_weight × temporal_boost |
| `pgmnemo.ef_search` | INT | `100` | SET LOCAL pgvector.hnsw.ef_search at recall entry |
| `pgmnemo.disable_hybrid` | BOOL | `false` | Force vector-only path in `recall_lessons()` |
| `pgmnemo.graph_proximity_weight` | FLOAT | `0.2` | δ on graph-proximity BFS term (0.0–0.5) |
| `pgmnemo.importance_weight` | FLOAT | `0.15` | Coefficient on importance/5 term |
| `pgmnemo.max_query_text_chars` | INT | `2000` | Max chars for query_text / lesson_text inputs; 0 = disabled |
| `pgmnemo.tenant_id` | TEXT | `''` | RLS scoping by project_id; empty = bypass |
| `pgmnemo.as_of_timestamp` | TIMESTAMPTZ | `''` | Point-in-time filter for bitemporal recall; set transaction-local by `recall_lessons()` |

### C7. Multi-Tenant / Role Scoping

- `project_id INT` + `role TEXT` = composite scope on `agent_lesson`.
- `role_filter=NULL` pools across roles.
- `project_id_filter=NULL` pools across projects.
- RLS via `pgmnemo.tenant_id` GUC: empty = service-account bypass; non-empty = only rows where `project_id::text = current_setting('pgmnemo.tenant_id')`.

### C8. Bitemporal `as_of` Recall

Columns `t_valid_from`, `t_valid_to` (added v0.5.0) on `agent_lesson`. `t_valid_to = 'infinity'::TIMESTAMPTZ` = currently active. Bitemporal trigger closes prior row on same `content_hash` insert. `recall_lessons()` with `as_of_ts` restricts to `t_valid_from ≤ as_of_ts < t_valid_to`. Connection-pool-safe (set as transaction-local GUC).

---

## Part D — Gap Analysis (What ANSE/pgmnemo Addresses That Existing Docs Don't Explain)

1. **Single-plan multimodal fusion** — not articulated anywhere in current public docs as a first-class differentiator. All docs describe the retrieval components separately; none explain that they execute inside one SQL plan that the optimizer manages.

2. **Token-economy navigation pattern** (`locate`→`expand`) — entirely absent from all public docs. This is the primary new capability of v0.8.0 and directly addresses context-token bloat.

3. **EXPLAIN-able recall** — zero mention in any doc. This is a unique advantage over all SaaS RAG services and should be a first-level bullet.

4. **Outcome-learning loop** (`reinforce`, `confidence`, `match_confidence`) — shipped v0.7.x, absent from USAGE.md and SQL_REFERENCE.md.

5. **Graph-proximity calibration** — `pgmnemo.graph_proximity_weight` GUC exists, documented in SQL_REFERENCE GUC table, but no narrative explains *when and why to tune it*, and the calibration story (set to 0.0 for pure semantic bench; increase for corpora with rich causal/temporal edges) is absent.

6. **Version synchronization failure** — README badge, WHY_PGMNEMO "honest state" section, USAGE.md scoring formula, SQL_REFERENCE version header, and ROADMAP releases table are all at different version epochs (0.4.1 to 0.7.2) despite 0.8.0 shipping 2026-06-03.

---

## Part E — Priority Action List for WRITE-AGENTS + FIX-POSITIONING

### P0 (Blocking for 0.8.1 launch)
1. Update all version strings to `0.8.0` (or `0.8.1`) across README, USAGE, SQL_REFERENCE, WHY_PGMNEMO, CHANGELOG badge.
2. Remove internal-strategy content from ROADMAP.md (WG-STRAT, T1/T2/T3 threat postures, core-team workflow reference, "wedge customer (internal)").
3. Add `navigate_locate` + `navigate_expand` documentation to SQL_REFERENCE + USAGE.
4. Add `reembed`, `reembed_batch`, `recompute_content` documentation to SQL_REFERENCE + USAGE.
5. Add `reinforce()` documentation to SQL_REFERENCE + USAGE.
6. Add `source_type` + `embedding_at` to SQL_REFERENCE schema table.
7. Fix `recall_hybrid()` signature in SQL_REFERENCE (add `confidence`, `match_confidence` trailing columns).
8. Fix SQL_REFERENCE `state` default from `'candidate'` to `'draft'`.
9. Fix SQL_REFERENCE `source_run_id` type from `BIGINT` to `TEXT`.
10. Update ROADMAP releases table: mark v0.7.0/0.7.1/0.7.2 as SHIPPED, add v0.8.0 row.

### P1 (Positioning reframe)
11. Rewrite README "Why this exists" section around single-plan multimodal fusion as the headline differentiator. Current framing ("one differentiator = provenance gate") undersells.
12. Add "EXPLAIN-able ranking" as an explicit bullet in all positioning docs.
13. Update POSITIONING.md differentiator claim to include: graph proximity + JSONB pushdown + relational, all in one SQL plan.
14. Update benchmark numbers: LME 0.9604 (v0.6.2), LoCoMo current epoch (confirm latest gate file).
15. Add token-economy navigation as a capability axis in POSITIONING.md competitor matrix.
16. Add outcome-learning capability to POSITIONING.md.

### P2 (Polish)
17. Sync "honest current state" across WHY_PGMNEMO + POSITIONING.md (production user count, latest release).
18. Add `as_of_ts` bitemporal recall to USAGE.md with example.
19. Add stats() v0.7.0 confidence-distribution columns to SQL_REFERENCE.
20. Add graph-proximity calibration narrative to USAGE.md.
21. Redact or archive MAGMA §-numbered strategy references from ROADMAP.
