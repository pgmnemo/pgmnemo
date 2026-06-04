# Why pgmnemo

**Audience:** an engineer evaluating agent-memory options in 5 minutes.
**For regulated/enterprise context:** see [WHY_PGMNEMO_ENTERPRISE.md](WHY_PGMNEMO_ENTERPRISE.md).

---

## The problem

AI agents accumulate memories — lessons, observations, summaries — to use
across runs. Three failure modes compound as the corpus grows:

1. **Hallucinated memories accumulate silently.** Vector stores and cloud
   memory APIs store whatever the agent says. None enforce that a memory
   was derived from a verifiable artifact at write time. Broken agent runs
   produce plausible-but-wrong memories that poison every future recall.

2. **Retrieval quality is opaque.** Score = some float from a black box
   or a separate service. You cannot EXPLAIN why a memory ranked first.
   You cannot regression-test the ranking with SQL.

3. **Context-token bloat.** Without budget discipline, retrieval returns
   full lesson texts for everything above a threshold. Agents receive
   8,000 tokens of memory and act on 200.

---

## What pgmnemo is

A PostgreSQL extension — `CREATE EXTENSION pgmnemo CASCADE` — no separate
service, no API key, no SaaS endpoint.

**Single-plan multimodal fusion inside your existing Postgres.** pgmnemo
ranks across four retrieval channels in one SQL query plan: HNSW vector
(pgvector), BM25 full-text (tsvector/GIN), graph-edge proximity (`mem_edge`
BFS), and JSONB metadata predicate pushdown (GIN index). The PostgreSQL
optimizer manages the join, filter, and sort. You call one function.

What you get:

1. **Provenance gate.** Every `pgmnemo.ingest(...)` requires a `commit_sha`
   or `artifact_hash`. Without one, the write is blocked (or warned, your
   choice). Enforced inside SQL — your application code cannot bypass it.
   Phantom memories from broken agent runs cannot enter long-term storage.

2. **Single-plan hybrid retrieval.** Vector + BM25 + graph proximity + JSONB
   pushdown in one SQL call. EXPLAIN-able — run `EXPLAIN (ANALYZE, BUFFERS)`
   on any recall query and see the full execution plan:

   ```sql
   SELECT lesson_id, score, lesson_text, match_confidence
   FROM pgmnemo.recall_hybrid(my_embedding, 'JWT rotation', k := 10);
   ```

3. **Token-economy navigation.** `navigate_locate()` returns ranked IDs
   within a configurable character budget. `navigate_expand()` fetches
   full content + graph neighbors only for the IDs you choose:

   ```sql
   -- Step 1: locate cheaply (no full text returned)
   SELECT id, preview, score, tokens_consumed
   FROM pgmnemo.navigate_locate(my_embedding, 'JWT rotation', 4000);

   -- Step 2: expand only what you need
   SELECT id, content, graph_neighbor_ids
   FROM pgmnemo.navigate_expand(ARRAY[42, 99]);
   ```

4. **Outcome-learning.** `reinforce(lesson_id, 'success')` raises confidence;
   `reinforce(lesson_id, 'failure')` lowers it. `recall_hybrid()` returns
   `match_confidence [0,1]` — use it to gate whether a retrieved memory is
   worth passing to your agent's context.

5. **Multi-tenant scoping.** Row-Level Security at the database layer. `SET
   pgmnemo.tenant_id = '42'` restricts the session to that project —
   enforced by Postgres, not by your application code.

6. **Apache-2.0 source.** PGXN-distributed. Backup with `pg_dump`.
   Replicate with logical replication. Same operational model as the rest
   of your stack.

---

## Why us, specifically

- **You already run PostgreSQL.** Install is one SQL command. No new container.
- **You already pay for a database.** We add zero per-call cost and zero data egress.
- **You want EXPLAIN-able ranking.** Every recall query is a SQL function — run
  `EXPLAIN (ANALYZE, BUFFERS)` and see the full plan. Impossible with any external
  RAG service.
- **You care about context-token budget.** `navigate_locate()` + `navigate_expand()`
  give you a two-step pattern that bounds exactly how much text reaches your agent.
- **You've watched a hallucinated memory poison a downstream run.** You want a
  structural fix (block-at-write) not an after-the-fact filter.
- **You care that benchmarks reproduce.** We publish `raw_retrievals.jsonl` so
  you can re-score on your own metric.

---

## Don't choose us if

- You need a managed SaaS with a polished web UI today → **use Mem0 or Zep**
- You need LLM-driven, real-time contradiction resolution across a continuously-growing global knowledge graph → **use a purpose-built graph service**
- You need billion-row vector retrieval at sub-10ms p99 → **use a dedicated vector DB**
- You're not on PostgreSQL and don't want to be → **anything else**

---

## What you get in 30 minutes

```bash
# 1. Add to your Dockerfile (or run on host with pg_config)
FROM pgvector/pgvector:pg17
ADD https://github.com/pgmnemo/pgmnemo/releases/download/v0.8.1/pgmnemo-0.8.1.zip /tmp/
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/pgmnemo-0.8.1.zip -d /tmp/ \
    && cp -r /tmp/pgmnemo-0.8.1/extension/* \
          /usr/share/postgresql/17/extension/ \
    && rm -rf /tmp/pgmnemo-0.8.1*
```

```sql
-- 2. In your database
CREATE EXTENSION pgmnemo CASCADE;

-- 3. Replace your memory-write
SELECT pgmnemo.ingest(
    p_role        := 'research-agent',
    p_project_id  := 1,
    p_topic       := 'security',
    p_lesson_text := 'JWT tokens rotated; 24h window since last compromise',
    p_commit_sha  := 'a3f9b12'  -- ← provenance token, this is the gate
);

-- 4a. Standard hybrid recall
SELECT lesson_id, score, lesson_text, match_confidence
FROM pgmnemo.recall_hybrid(
    my_query_embedding,
    'token rotation policy',
    k := 10
);

-- 4b. Token-economy pattern: locate IDs within budget, then expand only what you need
SELECT id, preview, score, tokens_consumed
FROM pgmnemo.navigate_locate(my_query_embedding, 'token rotation', 4000);
-- → returns ranked IDs + 50-char previews; total chars ≤ 4000

SELECT id, content, graph_neighbor_ids
FROM pgmnemo.navigate_expand(ARRAY[42, 99]);
-- → full lesson_text + graph neighbors for chosen IDs only

-- 5. Verify install
SELECT version, lesson_count, embedding_coverage_pct,
       hybrid_enabled, ghost_count, confidence_mean
FROM pgmnemo.stats();
```

Full install guide (Docker / PGXN / vendored): [docs/INSTALL.md](INSTALL.md).

---

## Honest current state

- **Latest release:** v0.8.0 (2026-06-03)
- **Bench numbers:** LoCoMo session recall@10 = 0.8409 (paper-canonical, session-level, 22× smaller search space than paper Table 3); LongMemEval-S = 0.9604 (hybrid RRF Fix-A v0.6.2 — gap to BM25 baseline 0.982 narrowed from −5pp to −2.2pp, p=0.017)
- **License:** Apache-2.0, no CLA

We will not claim numbers we cannot reproduce. Full benchmark methodology and per-version history: [docs/BENCHMARK_PROTOCOL.md](BENCHMARK_PROTOCOL.md) and [benchmarks/METRICS_BY_VERSION.md](../benchmarks/METRICS_BY_VERSION.md). The honest competitive position: [docs/COMPETITIVE_REALITY.md](COMPETITIVE_REALITY.md).

---

## What we want from you

1. **Try the 30-minute install** on a non-prod database.
2. **Tell us whether the provenance gate solves your hallucinated-memory
   problem.** Yes? Great. No? Tell us why — we want that signal more than
   we want a star.
3. **If yes:** pilot for 30 days, share metrics, we'll cite you on
   [ADOPTION.md](ADOPTION.md) (named or anonymous, your choice).
4. **If you ship a memory bug into production**, coordinated disclosure
   path: [SECURITY.md](../SECURITY.md).

GitHub: https://github.com/pgmnemo/pgmnemo · PGXN: https://pgxn.org/dist/pgmnemo/
