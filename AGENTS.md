# pgmnemo — Agent Integration Guide

**Version:** 0.8.0  
**License:** Apache-2.0  
**Install:** `CREATE EXTENSION pgmnemo CASCADE` in your existing PostgreSQL database.

This document is the canonical reference for an AI agent or developer evaluating
or integrating pgmnemo. One read covers: what it is, when to adopt it, every
capability with working SQL, and how to measure adoption ROI.

---

## 1. What pgmnemo is — and the problem it solves

### The problem

AI agents accumulate memory — lessons, observations, summaries, decisions — that
must persist across runs and be recalled at query time. The dominant approaches
each introduce the same failure cluster:

| Symptom | Root cause |
|---|---|
| **Scattered stores, split query plans** | Vector search, keyword search, graph edges, and metadata filters live in separate systems. Final ranking happens in application code. No single EXPLAIN shows why a memory ranked first. |
| **Data egress on every write** | Cloud memory APIs send observations to vendor infrastructure for LLM-powered fact extraction (~$0.17–$0.36 per 1,000 writes). Every write crosses a trust boundary you don't own. |
| **Context-token bloat** | Retrieval without budget discipline returns full lesson texts for everything above a score threshold. Agents receive 8,000 tokens of memory and use 200. |
| **Opaque ranking** | Score = some float from a black box. You cannot EXPLAIN it, regression-test it, or tune it without guess-and-check. |
| **Hallucinated memory accumulates silently** | No write-path enforcement links a memory to a verifiable artifact. Broken agent runs produce plausible-but-wrong memories that survive all future recalls. |

### The solution: single-plan multimodal fusion inside your existing Postgres

pgmnemo is a PostgreSQL extension (`CREATE EXTENSION pgmnemo CASCADE`) — no
separate service, no API key, no new container.

It ranks across four retrieval channels inside **one SQL query plan**:

```
HNSW vector search (pgvector)
  + BM25 full-text (tsvector / GIN index)
  + graph-edge proximity (mem_edge BFS, causal + temporal)
  + JSONB metadata predicate pushdown (GIN index)
  + relational filters (role, project_id, state, verified_at)
```

PostgreSQL's query optimizer manages the join, filter, and sort.
You call one function; the database handles everything else.

### Architectural consequences

Because everything executes inside your database:

| Property | What it means |
|---|---|
| **Zero data egress** | Embeddings, graph edges, metadata, and scoring never leave your Postgres at retrieval time. |
| **$0 LLM-free ingestion** | `ingest()` is a SQL constraint check + indexed INSERT. No model API call on the write path. |
| **EXPLAIN-able ranking** | `EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM pgmnemo.recall_lessons(...)` shows the full execution plan. Tune with evidence, not intuition. |
| **ACID incremental updates** | `reembed()`, `reembed_batch()`, `recompute_content()` patch rows in-place under full ACID. No re-ingestion pipeline needed. |
| **Provenance-gated writes** | `pgmnemo.gate_strict = 'enforce'` blocks writes without a `commit_sha` or `artifact_hash` at the constraint layer. Application code cannot bypass this without SUPERUSER. |
| **Outcome-learning** | `reinforce(lesson_id, 'success')` raises confidence; `reinforce(lesson_id, 'failure')` lowers it. Confidence feeds back into recall scoring and is returned as an interpretable `match_confidence [0,1]` signal. |
| **Bitemporal point-in-time recall** | `recall_lessons(..., as_of_ts := '2026-01-01')` restricts candidates to the validity window `t_valid_from ≤ as_of_ts < t_valid_to`. Time-travel your agent's memory. |
| **Token-economy navigation** | `navigate_locate()` returns IDs within a character budget. `navigate_expand(ids)` fetches content + graph neighbors for the IDs you choose. Locate cheaply; expand only what you need. |

---

## 2. When to adopt / when not to

### Adopt pgmnemo if

- **You already run PostgreSQL** (v14–v17). Install is one SQL command. No new service.
- **Your memory corpus is 10k–10M rows.** HNSW on pgvector and GIN indexes scale
  comfortably in this range on modest hardware.
- **You want zero per-call LLM cost.** Memory writes and reads are pure SQL.
- **You want EXPLAIN-able, regression-testable recall.** Every recall function is
  a plain SQL function you can inspect.
- **You need multi-tenant isolation.** `project_id` + `role` scoping with row-level
  security is built in.
- **You have compliance requirements.** Set `gate_strict = 'enforce'` and every
  write is rejected at the Postgres constraint layer unless it carries a verifiable
  artifact hash or commit SHA.
- **You want incremental embedding updates.** `reembed_batch()` lets you re-embed
  your corpus as your model changes without re-ingesting or re-creating rows.

### Do not adopt pgmnemo if

- You need a **global-synthesis knowledge graph** that LLM-resolves contradictions
  across millions of facts in real time. That requires a purpose-built graph
  service with LLM inference on every write.
- You need **billion-row retrieval at sub-10ms p99**. Use a dedicated vector
  database for that scale.
- You want a **fully managed SaaS** with zero infrastructure. Use Mem0 Cloud or Zep.
- You are **not on PostgreSQL** and do not want to be.

---

## 3. Capability map

### 3.1 Write path

#### `pgmnemo.ingest()` — validated memory write

```sql
SELECT pgmnemo.ingest(
    p_role          := 'research-agent',   -- agent role string (required)
    p_project_id    := 1,                  -- tenant / project (required)
    p_topic         := 'security',         -- short label (required)
    p_lesson_text   := 'Rotate JWT secrets within 24h of key-compromise.',
    p_importance    := 4,                  -- 1 (low) to 5 (critical), default 3
    p_embedding     := $1::vector(1024),   -- 1024-dim dense vector (NULL = text-only)
    p_commit_sha    := 'a3f9b12',          -- provenance: git SHA that produced this lesson
    p_artifact_hash := NULL,               -- provenance: sha256 of artifact (alt to commit_sha)
    p_metadata      := '{"model":"claude-sonnet-4-6","run_id":"r-42"}'::jsonb
);
-- Returns BIGINT: the new lesson_id
```

**Provenance gate** (controlled by `pgmnemo.gate_strict`):

| Mode | Behavior |
|---|---|
| `'enforce'` (default) | Rejects INSERT if both `commit_sha` and `artifact_hash` are NULL. Transaction aborts. |
| `'warn'` | Accepts INSERT, emits WARNING, leaves `verified_at` NULL ("ghost lesson", excluded from recall by default). |
| `'off'` | No check. Development only. |

Ghost lessons (`verified_at IS NULL`) are excluded from all recall functions unless
`SET pgmnemo.include_unverified = 'true'` for the session.

**`source_type` column** (v0.8.0): classifies the lesson's origin. Set via raw INSERT
or upstream metadata; not a parameter of `ingest()`. Values:

| Value | Meaning |
|---|---|
| `'auto_captured'` | Default. Automatically generated from agent output. |
| `'agent_authored'` | Explicitly composed by an agent. |
| `'imported'` | Loaded from an external system. |
| `'system'` | Created by pgmnemo internal processes. |

---

#### `pgmnemo.reinforce()` — outcome-learning feedback

Record what happened after a lesson was used. Confidence feeds back into scoring
and is returned as `match_confidence` in recall output.

```sql
-- Single lesson — returns new confidence REAL [0,1]
SELECT pgmnemo.reinforce(lesson_id := 42, p_outcome := 'success');
-- 'success' → confidence += 0.10, increments success_count
-- 'failure' → confidence -= 0.15, increments fail_count
-- 'neutral' → no-op, returns current confidence

-- Batch (v0.7.1) — returns count of rows updated
SELECT pgmnemo.reinforce(
    p_lesson_ids := ARRAY[42, 99, 137]::BIGINT[],
    p_outcome    := 'failure'
);
-- Missing IDs skipped silently. Unknown outcome string raises EXCEPTION.
```

Outcome strings are exact: `'success'`, `'failure'`, `'neutral'`.

---

#### `pgmnemo.reembed()` / `pgmnemo.reembed_batch()` — embedding refresh (v0.8.0)

Refresh vectors without creating new bitemporal rows. Use when your embedding model
changes or when you want to backfill embeddings for text-only rows.

```sql
-- Single row
SELECT pgmnemo.reembed(
    p_lesson_id  := 42,
    p_new_vector := $1::vector(1024)
);
-- Updates embedding + embedding_at. Raises if lesson not found or not active.
-- Does NOT change lesson_text, content_hash, or create a new bitemporal row.

-- Batch (use ascending ID order to prevent deadlocks)
SELECT pgmnemo.reembed_batch(
    p_lesson_ids  := ARRAY[10, 11, 42, 99]::BIGINT[],
    p_new_vectors := ARRAY[$1, $2, $3, $4]::vector[]
);
-- Returns INT: count of rows actually updated.
-- Uses FOR UPDATE SKIP LOCKED — rows locked by concurrent ingest() are skipped safely.
```

---

#### `pgmnemo.recompute_content()` — in-place text update (v0.8.0)

Correct or update `lesson_text` in-place without triggering bitemporal close+create
churn. Cascades automatically: `content_hash` (GENERATED ALWAYS AS), `lesson_tsv`
(trigger), `updated_at` (trigger).

```sql
SELECT pgmnemo.recompute_content(
    p_lesson_id := 42,
    p_new_text  := 'Rotate JWT secrets within 12h of key-compromise (updated threshold).'
);
-- Preserves: id, embedding (now stale — follow up with reembed()), mem_edges,
-- provenance, confidence, source_type.
-- Raises if lesson not found or not active (t_valid_to = infinity).
-- After calling, embedding is stale; follow with reembed() if needed.
```

---

#### `pgmnemo.add_edge()` — typed graph edge (v0.5.0)

Idempotent writer for the `mem_edge` graph. Edges are traversed during recall
BFS and scored via `graph_proximity_weight`.

```sql
-- Simple: 5-param form (mode = 'replace' by default)
SELECT pgmnemo.add_edge(
    p_source_id     := 101,           -- earlier / cause lesson
    p_target_id     := 205,           -- later / effect lesson
    p_relation_type := 'CAUSED_BY',   -- freeform; maps to edge_kind automatically
    p_weight        := 0.85,          -- confidence [0,1]
    p_metadata      := '{"run_id":7320}'::jsonb
);

-- Full control: 6-param form
SELECT pgmnemo.add_edge(101, 205, 'CAUSED_BY', 0.85, '{}', 'max');
-- p_mode: 'replace' (last-write-wins) | 'max' (monotonic) | 'avg' (running mean)
```

Canonical `relation_type` → `edge_kind` mapping:

| relation_type | edge_kind |
|---|---|
| `CAUSED_BY`, `DERIVED_FROM`, `CONTRADICTS` | `causal` |
| `CO_OCCURRED` | `temporal` |
| `ENTITY_LINK`, `SHARED_TAG` | `entity` |
| anything else | `semantic` |

---

### 3.2 Recall path

#### `pgmnemo.recall_lessons()` — primary hybrid recall

```sql
SELECT lesson_id, score, topic, lesson_text, importance,
       vec_score, bm25_score, rrf_score
FROM pgmnemo.recall_lessons(
    query_embedding   := $1::vector(1024),  -- NULL for text-only
    k                 := 10,                -- max results (default 10)
    role_filter       := 'research-agent',  -- NULL = all roles
    project_id_filter := 1,                 -- NULL = all projects
    query_text        := 'JWT secret rotation',  -- activates BM25 hybrid path
    as_of_ts          := NULL               -- NULL = current; TIMESTAMPTZ for point-in-time
)
ORDER BY score DESC;
```

**Scoring (hybrid path, Fix-A RRF v0.6.2):**
```
score = rrf_diag/norm_denom
      + aux(importance, recency_90d, provenance_strength)
      + graph_proximity_weight × graph_proximity_BFS
```
where `rrf_diag = vec_weight/(rrf_k+vec_rank) + bm25_weight/(rrf_k+bm25_rank)`.

**Scoring (vector-only path, when `query_text` is NULL or hybrid disabled):**
```
score = 0.4×cosine + 0.2×(importance/5) + γ×recency(90d) + 0.1×prov_strength + δ×graph_proximity
```

Output columns include diagnostic `vec_score`, `bm25_score`, `rrf_score`
(appended at end; named-column callers unaffected).

---

#### `pgmnemo.recall_hybrid()` — direct hybrid call with confidence output

```sql
SELECT lesson_id, score, topic, lesson_text,
       confidence,       -- outcome-learning confidence [0,1]
       match_confidence  -- calibrated cosine similarity [0,1] (BUG-1 fix v0.7.1)
FROM pgmnemo.recall_hybrid(
    query_embedding   := $1::vector(1024),
    query_text        := 'JWT rotation',
    k                 := 10,
    role_filter       := 'research-agent',
    project_id_filter := 1,
    vec_weight        := 0.4,    -- default
    bm25_weight       := 0.4,    -- default
    rrf_k             := 60      -- default
)
ORDER BY score DESC;
```

`match_confidence` is a calibrated, interpretable retrieval-match signal in [0,1]
(uses cosine similarity, not the RRF score). Use it to decide whether the top result
is a genuine match before consuming it in your agent's context.

---

#### `pgmnemo.navigate_locate()` — token-budget LOCATE (v0.8.0)

Returns ranked lesson IDs within a cumulative character budget. **No lesson text
returned here** — that keeps this call cheap. Pass the IDs to `navigate_expand()`
to fetch content for the subset you actually want.

```sql
SELECT id, preview, score, tokens_consumed, navigation_path
FROM pgmnemo.navigate_locate(
    query_embedding    := $1::vector(1024),  -- NULL if query_text provided
    query_text         := 'JWT rotation',    -- NULL if query_embedding provided
    token_budget_chars := 4000,              -- cumulative char budget (default 2000)
    jsonb_filter       := '{"project":"infra"}'::jsonb  -- NULL for no metadata filter
)
ORDER BY score DESC;
-- Returns: id, preview (first 50 chars), score, tokens_consumed, navigation_path
-- navigation_path: 'jsonb_gate' | 'vector' | 'bm25'
-- First row always returned even if its length exceeds budget.
-- tokens_consumed is cumulative INCLUDING the current row.
```

The `jsonb_filter` predicate is pushed into the GIN index on `metadata`
(`WHERE metadata @> jsonb_filter`). This narrows the candidate set before
any vector or BM25 computation.

Uses the same scoring formula as `recall_hybrid` v0.6.2 — graph BFS is capped at
2 hops at the locate phase (deeper expansion is `navigate_expand`'s role).

---

#### `pgmnemo.navigate_expand()` — on-demand content + graph expansion (v0.8.0)

Fetches full `lesson_text` and optional graph neighbors for IDs you selected
from `navigate_locate()`. Call this only for the subset of IDs your agent
will actually read.

```sql
SELECT id, content, expand_detail, graph_neighbor_ids, graph_neighbor_previews,
       tokens_consumed, navigation_path
FROM pgmnemo.navigate_expand(
    ids                    := ARRAY[42, 99, 137]::BIGINT[],
    expand_fields          := ARRAY['model', 'run_id'],  -- project these keys from metadata JSONB
    graph_expand_depth     := 1,    -- BFS depth for causal+temporal neighbors (0 = none)
    graph_expand_threshold := 0.7   -- minimum edge weight to traverse
)
ORDER BY id ASC;
-- id:                    the lesson ID
-- content:               full lesson_text
-- expand_detail:         JSONB projection of requested expand_fields from metadata
-- graph_neighbor_ids:    array of neighbor IDs discovered by BFS (NULL for expanded rows)
-- graph_neighbor_previews: first 50 chars of each neighbor's lesson_text
-- tokens_consumed:       cumulative char count across all rows (running sum)
-- navigation_path:       'content' for requested IDs; 'graph_expand' for BFS neighbors
```

---

#### `pgmnemo.traverse_causal_chain()` — explicit BFS over causal edges

```sql
SELECT lesson_id, depth, path, path_weight, topic, lesson_text
FROM pgmnemo.traverse_causal_chain(
    start_id       := 42,
    max_depth      := 5,
    relation_types := ARRAY['CAUSED_BY', 'DERIVED_FROM'],  -- default
    only_active    := TRUE,
    direction      := 'both'   -- 'forward' | 'backward' | 'both'
)
ORDER BY depth, path_weight DESC;
```

---

#### `pgmnemo.traverse_temporal_window()` — co-temporal episode discovery

```sql
SELECT lesson_id, time_delta_sec, linked, edge_weight, topic, lesson_text
FROM pgmnemo.traverse_temporal_window(
    start_id          := 42,
    window_interval   := INTERVAL '30 minutes',
    include_unlinked  := TRUE,       -- include lessons with no direct edge
    role_filter       := NULL,
    project_id_filter := 1,
    k                 := 20
)
ORDER BY time_delta_sec ASC;
-- linked=TRUE when a mem_edge exists between start_id and this row.
```

---

### 3.3 Diagnostics

#### `pgmnemo.stats()` — one-row health snapshot

```sql
SELECT * FROM pgmnemo.stats();
-- 19 columns (v0.8.0):
-- version, lesson_count, embedded_count, embedding_coverage_pct, tsv_coverage_pct
-- mem_edge_count, recency_weight, ef_search, importance_weight
-- hybrid_enabled, recall_hybrid_available, oldest_lesson_age_days, orphan_count
-- ghost_count           -- active lessons with verified_at IS NULL (provenance debt)
-- confidence_mean       -- corpus-wide mean confidence
-- confidence_p10        -- 10th percentile confidence
-- confidence_p50        -- median confidence
-- confidence_p90        -- 90th percentile confidence
-- confidence_below_threshold_count  -- lessons with confidence < 0.3

-- Quick checks:
SELECT embedding_coverage_pct FROM pgmnemo.stats();  -- 0.0 = no embeddings; text-only path only
SELECT ghost_count, lesson_count FROM pgmnemo.stats();  -- provenance debt audit
SELECT confidence_mean, confidence_p50 FROM pgmnemo.stats();  -- outcome-learning health
```

#### `pgmnemo.recall_stats` view — call-count observability

```sql
SELECT * FROM pgmnemo.recall_stats;
-- schema | function_name | calls | total_time | self_time | observed_at
-- Requires: track_functions = 'pl' in postgresql.conf
```

---

### 3.4 Key GUCs

Set GUCs via `SET` (session), `SET LOCAL` (transaction), or `ALTER SYSTEM` (persistent).
Read via `SELECT current_setting('pgmnemo.X', TRUE)` or `SELECT * FROM pgmnemo.stats()`.

> **Note:** pgmnemo is a pure-SQL extension; `SHOW pgmnemo.*` will fail.
> Use `current_setting()` or `pgmnemo.stats()`.

| GUC | Default | Effect |
|---|---|---|
| `pgmnemo.gate_strict` | `'enforce'` | Provenance gate: `enforce` \| `warn` \| `off` |
| `pgmnemo.include_unverified` | `'false'` | Include ghost lessons in recall |
| `pgmnemo.recency_weight` | `'0.05'` | γ on 90-day recency decay term |
| `pgmnemo.temporal_boost` | `'1.0'` | Multiplier on recency: effective_γ = recency_weight × temporal_boost |
| `pgmnemo.ef_search` | `'100'` | pgvector HNSW ef_search at recall entry (10–500) |
| `pgmnemo.graph_proximity_weight` | `'0.2'` | δ on graph-edge BFS proximity term (0.0–0.5; 0.0 = pure semantic) |
| `pgmnemo.disable_hybrid` | `'false'` | Force vector-only path even when query_text is provided |
| `pgmnemo.importance_weight` | `'0.15'` | Coefficient on `importance/5` term |
| `pgmnemo.max_query_text_chars` | `'2000'` | Max input length for lesson_text / query_text; 0 = unlimited |
| `pgmnemo.tenant_id` | `''` | RLS scoping by project_id; empty = service-account bypass |

---

## 4. Adoption recipes

### Recipe 1: Memory for an agent loop

The standard integration: write lessons from successful runs, read context at the
start of each run, reinforce based on outcome.

```sql
-- === WRITE: after an agent run produces a verifiable lesson ===
SELECT pgmnemo.ingest(
    p_role          := 'research-agent',
    p_project_id    := 1,
    p_topic         := 'auth-service',
    p_lesson_text   := 'Bearer token expiry is 15min; refresh 60s before expiry to avoid 401s.',
    p_importance    := 4,
    p_embedding     := $1::vector(1024),     -- embed lesson_text with your embedder
    p_commit_sha    := 'abc1234',            -- commit SHA from the run that produced this
    p_metadata      := '{"agent":"research-agent","run_id":"r-99"}'::jsonb
);

-- === READ: at start of each run, recall relevant context ===
SELECT lesson_id, score, topic, lesson_text, match_confidence
FROM pgmnemo.recall_hybrid(
    query_embedding   := $1::vector(1024),   -- embed the current query/task
    query_text        := 'bearer token refresh auth',
    k                 := 5,
    role_filter       := 'research-agent',
    project_id_filter := 1
)
WHERE match_confidence > 0.3                 -- filter low-signal results
ORDER BY score DESC;

-- === REINFORCE: after the run, record outcome ===
SELECT pgmnemo.reinforce(
    p_lesson_id := 42,           -- ID from ingest() or recall output
    p_outcome   := 'success'     -- 'success' | 'failure' | 'neutral'
);
```

---

### Recipe 2: Token-economy retrieval

When your context window budget is a constraint, use `navigate_locate` → `navigate_expand`
to locate IDs cheaply, then fetch content only for what you actually need.

```sql
-- Step 1: locate ranked IDs within a token budget (no full content returned)
WITH located AS (
    SELECT id, preview, score, tokens_consumed, navigation_path
    FROM pgmnemo.navigate_locate(
        query_embedding    := $1::vector(1024),
        query_text         := 'bearer token refresh',
        token_budget_chars := 6000,                      -- cumulative char budget
        jsonb_filter       := '{"agent":"research-agent"}'::jsonb  -- metadata pre-filter
    )
    WHERE score > 0.01
),
-- Step 2: expand full content only for the top 3 (or however many fit your budget)
expanded AS (
    SELECT e.id, e.content, e.expand_detail,
           e.graph_neighbor_ids, e.graph_neighbor_previews,
           e.tokens_consumed, e.navigation_path
    FROM pgmnemo.navigate_expand(
        ids                    := (SELECT array_agg(id ORDER BY score DESC) FROM located LIMIT 3),
        expand_fields          := ARRAY['run_id', 'model'],   -- keys to pull from metadata
        graph_expand_depth     := 1,          -- follow 1-hop causal/temporal neighbors
        graph_expand_threshold := 0.7
    ) e
)
SELECT * FROM expanded ORDER BY id;
```

**Why this pattern?**  
`navigate_locate` returns only `id`, `preview` (50 chars), and scores — no full text.
For a corpus of 100k lessons, you evaluate ranking for all candidates without
transmitting 100k lesson bodies to your application. You then call `navigate_expand`
only for the 2–5 lessons your agent will actually read. Total round-trip content
is bounded by your choice of IDs, not by the corpus size.

---

### Recipe 3: Multi-tenant scoping

pgmnemo uses `project_id` + `role` for row-level scoping, with optional RLS
enforcement via the `pgmnemo.tenant_id` GUC.

```sql
-- Option A: parameter-level scoping (no RLS enforcement; use in trusted contexts)
SELECT lesson_id, score, lesson_text
FROM pgmnemo.recall_lessons(
    query_embedding   := $1::vector(1024),
    query_text        := 'deployment checklist',
    role_filter       := 'ops-agent',
    project_id_filter := 42               -- hard tenant scoping at query time
);

-- Option B: session-level RLS (enforced by Postgres, not by your application)
-- At session start:
SET pgmnemo.tenant_id = '42';
-- Now all queries on agent_lesson and mem_edge are restricted to project_id = 42.
-- Unset (empty string) = service-account bypass (all rows visible).

-- To pool across roles within a project (e.g., admin view):
SELECT lesson_id, role, score, lesson_text
FROM pgmnemo.recall_lessons(
    query_embedding   := $1::vector(1024),
    query_text        := 'security policy',
    role_filter       := NULL,             -- NULL = all roles
    project_id_filter := 42
);
```

---

### Recipe 4: Incremental embedding updates

When you switch embedding models, use `reembed_batch()` to refresh vectors in-place
without re-ingesting or touching the bitemporal history.

```sql
-- Identify rows needing refresh (e.g., embedded with old model)
SELECT id FROM pgmnemo.agent_lesson
WHERE is_active
  AND t_valid_to = 'infinity'
  AND (
      embedding IS NULL                                          -- never embedded
      OR (embedding_at < '2026-05-01'::timestamptz)             -- embedded before model change
      OR (metadata->>'embedder' != 'bge-m3')                    -- tagged with old model
  )
ORDER BY id ASC   -- ascending order prevents deadlocks in batch
LIMIT 500;

-- Then batch-refresh in your application:
-- 1. Fetch the lesson_texts for those IDs.
-- 2. Call your embedder to produce new vectors.
-- 3. Update in-place:
SELECT pgmnemo.reembed_batch(
    p_lesson_ids  := $1::BIGINT[],
    p_new_vectors := $2::vector[]
);
-- Returns: count of rows updated (may be < input if rows were locked by concurrent ingest).
-- Repeat until all rows refreshed.

-- Check progress:
SELECT embedded_count, lesson_count, embedding_coverage_pct FROM pgmnemo.stats();
```

---

### Recipe 5: Bitemporal point-in-time recall

Recall the state of your agent's memory as it existed at a specific timestamp.
Useful for auditing, debugging, or replaying historical agent runs.

```sql
-- Recall as the memory existed on 2026-01-15
SELECT lesson_id, score, topic, lesson_text, created_at
FROM pgmnemo.recall_lessons(
    query_embedding   := $1::vector(1024),
    query_text        := 'deployment procedure',
    k                 := 10,
    role_filter       := 'ops-agent',
    project_id_filter := 1,
    as_of_ts          := '2026-01-15 00:00:00 UTC'::timestamptz
)
ORDER BY score DESC;
-- Only lessons active at that timestamp are returned:
-- t_valid_from <= '2026-01-15' AND t_valid_to > '2026-01-15'
```

---

### Recipe 6: Provenance gate modes

```sql
-- Production: strict enforcement (default)
SET pgmnemo.gate_strict = 'enforce';
SELECT pgmnemo.ingest('agent', 1, 'auth', 'lesson text', 3, NULL, 'abc1234');
-- ↑ succeeds (commit_sha provided)

SELECT pgmnemo.ingest('agent', 1, 'auth', 'lesson text');
-- ↑ raises: "pgmnemo provenance gate [enforce]: INSERT rejected"

-- Development: allow unverified writes with a warning
SET pgmnemo.gate_strict = 'warn';
SELECT pgmnemo.ingest('agent', 1, 'auth', 'lesson text');
-- ↑ succeeds; emits WARNING; verified_at = NULL; excluded from recall by default

-- Include ghost lessons in recall (during migration or testing only)
SET pgmnemo.include_unverified = 'true';

-- Check provenance debt
SELECT ghost_count, lesson_count,
       ROUND(100.0 * ghost_count / NULLIF(lesson_count, 0), 1) AS ghost_pct
FROM pgmnemo.stats();
-- Target: ghost_pct < 5% before enabling strict recall filtering
```

---

## 5. Install and verify

Full installation guide (Docker, PGXN, vendored zip, native):
**[docs/INSTALL.md](docs/INSTALL.md)**

**Quick verify** after install:

```sql
-- In psql, after CREATE EXTENSION pgmnemo CASCADE:

-- 1. Confirm version
SELECT pgmnemo.version();
-- → '0.8.0'

-- 2. Health snapshot
SELECT version, lesson_count, embedding_coverage_pct,
       hybrid_enabled, ghost_count
FROM pgmnemo.stats();

-- 3. Write a test lesson (with gate in warn mode)
SET pgmnemo.gate_strict = 'warn';
SELECT pgmnemo.ingest(
    'test-agent', 1, 'verify', 'Installation verified.', 3, NULL, NULL, NULL, '{}'
);

-- 4. Read it back
SELECT lesson_id, score, lesson_text
FROM pgmnemo.recall_lessons(
    NULL::vector(1024), 5, 'test-agent', 1, 'installation verified'
);

-- 5. Token-economy verify
SELECT id, preview, score, tokens_consumed
FROM pgmnemo.navigate_locate(NULL, 'installation verified', 2000, NULL);
```

---

## 6. Evaluating adoption ROI

Use these metrics to determine whether pgmnemo improves your agent's outcomes
relative to your current memory approach.

### 6.1 Retrieval quality

Run your existing benchmark or use pgmnemo's built-in diagnostic columns:

```sql
-- After a recall call, inspect the scoring components:
SELECT lesson_id, score, vec_score, bm25_score, rrf_score,
       match_confidence, confidence
FROM pgmnemo.recall_hybrid(
    query_embedding := $1::vector(1024),
    query_text      := 'your query here',
    k               := 10
)
ORDER BY score DESC;
```

- `vec_score`: raw cosine similarity. Low values indicate semantic mismatch.
- `bm25_score`: keyword match signal. High when query keywords appear in lesson text.
- `rrf_score`: fused rank signal (RRF). Primary ordering component.
- `match_confidence`: calibrated [0,1] cosine. Use as a quality gate: filter results
  below `0.3` as likely noise.
- `confidence`: outcome-learning confidence from `reinforce()` calls. Low values
  flag lessons that have previously failed.

### 6.2 Token budget

Compare context tokens before and after adopting the navigate_locate → navigate_expand
pattern:

```sql
-- Measure actual characters returned by navigate_locate vs naive top-K recall
WITH locate_result AS (
    SELECT SUM(length(al.lesson_text)) AS naive_chars,
           (SELECT MAX(tokens_consumed) FROM pgmnemo.navigate_locate(
               $1, 'your query', 4000, NULL)) AS locate_chars,
           COUNT(*) AS k
    FROM pgmnemo.recall_lessons($1::vector(1024), 10, 'agent', 1, 'your query') r
    JOIN pgmnemo.agent_lesson al ON al.id = r.lesson_id
)
SELECT naive_chars, locate_chars,
       ROUND(100.0 * (1.0 - locate_chars::numeric / NULLIF(naive_chars,0)), 1)
           AS token_reduction_pct
FROM locate_result;
```

### 6.3 Write cost

```sql
-- Confirm $0 LLM cost: ingest() is a pure SQL call — no external service.
-- Measure throughput with EXPLAIN ANALYZE:
EXPLAIN (ANALYZE, BUFFERS)
SELECT pgmnemo.ingest(
    'agent', 1, 'perf-test', repeat('x', 500), 3,
    NULL, 'testsha', NULL, '{}'
);
-- Planning time + execution time = total write cost. No network round-trip.
```

### 6.4 Ranking inspectability

```sql
-- EXPLAIN the full recall plan — this is impossible with any external RAG service
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT lesson_id, score FROM pgmnemo.recall_hybrid(
    $1::vector(1024), 'JWT rotation', 10, 'research-agent', 1
);
-- You will see: HNSW index scan, GIN index scan, CTE (BFS graph walk),
-- hash joins, sort nodes — the complete optimizer plan.
```

### 6.5 Data residency

pgmnemo produces zero network egress during recall. You can verify by confirming
no external connections are opened during a recall call:

```sql
-- Check active backend connections during a recall:
SELECT count(*) FROM pg_stat_activity WHERE query LIKE '%recall%';
-- All execution is local to Postgres — no rows in pg_stat_activity with external hosts.
```

---

## Appendix: Function signature quick reference

| Function | Returns | Added |
|---|---|---|
| `ingest(role, project_id, topic, lesson_text, [importance, embedding, commit_sha, artifact_hash, metadata])` | `BIGINT` (lesson_id) | v0.1.0 |
| `recall_lessons(embedding, [k, role_filter, project_id_filter, query_text, as_of_ts])` | TABLE (12+3 diag cols) | v0.3.0 |
| `recall_hybrid(embedding, query_text, [k, role_filter, project_id_filter, vec_weight, bm25_weight, rrf_k])` | TABLE (incl. confidence, match_confidence) | v0.2.2 |
| `navigate_locate(embedding, query_text, [token_budget_chars, jsonb_filter])` | TABLE (id, preview, score, tokens_consumed, navigation_path) | v0.8.0 |
| `navigate_expand(ids, [expand_fields, graph_expand_depth, graph_expand_threshold])` | TABLE (id, content, expand_detail, neighbor_ids, neighbor_previews, tokens_consumed, navigation_path) | v0.8.0 |
| `reinforce(lesson_id, outcome)` | `REAL` (new confidence) | v0.7.0 |
| `reinforce(lesson_ids[], outcome)` | `INT` (count updated) | v0.7.1 |
| `reembed(lesson_id, new_vector)` | `void` | v0.8.0 |
| `reembed_batch(lesson_ids[], new_vectors[])` | `INT` (count updated) | v0.8.0 |
| `recompute_content(lesson_id, new_text)` | `void` | v0.8.0 |
| `add_edge(source_id, target_id, relation_type, [weight, metadata, mode])` | `void` | v0.5.0 |
| `traverse_causal_chain(start_id, [max_depth, relation_types, only_active, direction])` | TABLE | v0.2.0 |
| `traverse_temporal_window(start_id, [window_interval, include_unlinked, role_filter, project_id_filter, k])` | TABLE | v0.2.0 |
| `transition_lesson(lesson_id, new_state)` | `agent_lesson` row | v0.1.4 |
| `evict_expired_lessons()` | `INT` (count deleted) | v0.1.4 |
| `stats()` | TABLE (19 cols) | v0.4.1 |
| `recall_stats` (view) | TABLE | v0.6.0 |
| `version()` | `TEXT` | v0.0.1 |
| `get_temporal_boost()` | `FLOAT8` | v0.5.0 |

---

*Apache-2.0 — [github.com/pgmnemo/pgmnemo](https://github.com/pgmnemo/pgmnemo)*  
*Full SQL reference: [docs/SQL_REFERENCE.md](docs/SQL_REFERENCE.md) · Usage guide: [docs/USAGE.md](docs/USAGE.md)*
