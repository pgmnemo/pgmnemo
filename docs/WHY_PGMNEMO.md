# Why pgmnemo

**Audience:** an engineer evaluating agent-memory options in 5 minutes.
**For regulated/enterprise context:** see [WHY_PGMNEMO_ENTERPRISE.md](WHY_PGMNEMO_ENTERPRISE.md).

---

## The problem

Your AI agents accumulate "memories" — lessons, observations, summaries —
to use across runs. The agent that wrote them was sometimes wrong. When
the next agent reads them, it trusts the wrong memory as fact, and the
error compounds across runs.

Mem0, Zep, and pgvector all store whatever the agent says. None of them
ask **"where did this come from?"** at write time. We do.

---

## What pgmnemo is

A PostgreSQL extension — `CREATE EXTENSION pgmnemo CASCADE` — no separate
service, no API key, no SaaS endpoint.

Four things you get:

1. **Provenance gate.** Every `pgmnemo.ingest(...)` requires a `commit_sha`
   or `artifact_hash`. Without one, the write is blocked (or warned, your
   choice). Enforced inside SQL — your application code cannot bypass it.
   Phantom memories from broken agent runs cannot enter long-term storage.

2. **Hybrid retrieval.** Cosine similarity (HNSW via pgvector) + BM25
   (tsvector) + recency decay + importance weighting, in a single SQL call:

   ```sql
   SELECT lesson_id, score, lesson_text
   FROM pgmnemo.recall_lessons(my_embedding, k := 10, query_text := 'JWT rotation');
   ```

3. **Multi-tenant scoping.** Row-Level Security at the database layer, not
   your application layer. `SET pgmnemo.tenant_id = '42'` and the rest of
   the session sees only that tenant's data — enforced by Postgres, not by
   your code remembering to add `WHERE tenant_id=...` everywhere.

4. **Apache-2.0 source.** PGXN-distributed. Backup with `pg_dump`.
   Replicate with logical replication. Same operational model as the rest
   of your stack.

---

## Why us, specifically

- **You already run PostgreSQL.** Install is one SQL command. No new container.
- **You already pay for a database.** We add zero per-call cost.
- **You hate that Mem0/Zep want your data in their cloud.** We're never in their cloud.
- **You've watched a hallucinated memory poison a downstream run.** You want a
  structural fix (block-at-write) not an after-the-fact filter.
- **You care that benchmarks reproduce.** We publish `raw_retrievals.jsonl` so
  you can re-score on your own metric.

---

## Don't choose us if

- You need a managed SaaS with a polished web UI today → **use Mem0 or Zep**
- You need entity-relation-temporal reasoning over months of history → **use Zep**
- You need billion-row vector retrieval at sub-10ms p99 → **use a dedicated vector DB**
- You're not on PostgreSQL and don't want to be → **anything else**

---

## What you get in 30 minutes

```bash
# 1. Add to your Dockerfile (or run on host with pg_config)
FROM pgvector/pgvector:pg17
ADD https://github.com/pgmnemo/pgmnemo/releases/download/v0.4.1/pgmnemo-0.4.1.zip /tmp/
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/pgmnemo-0.4.1.zip -d /tmp/ \
    && cp /tmp/pgmnemo-0.4.1/extension/pgmnemo.control \
          /tmp/pgmnemo-0.4.1/extension/pgmnemo--*.sql \
          /usr/share/postgresql/17/extension/ \
    && rm -rf /tmp/pgmnemo-0.4.1*
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

-- 4. Replace your memory-read
SELECT lesson_text, score
FROM pgmnemo.recall_lessons(
    my_query_embedding,
    k          := 10,
    query_text := 'token rotation policy'
);

-- 5. Verify install
SELECT * FROM pgmnemo.stats();
-- → version, lesson_count, embedding_coverage_pct, hybrid_enabled, etc.
```

Full install guide (Docker / PGXN / vendored): [docs/INSTALL.md](INSTALL.md).

---

## Honest current state

- **Production user count:** 1 (Agency v2, 1081 lessons, 6 months — see [ADOPTION.md](ADOPTION.md))
- **Latest release:** v0.4.1 (2026-05-17)
- **Bench numbers:** LoCoMo session recall@10 = 0.84 (paper-canonical, +4pp vs v0.4.0 vector-only); LongMemEval-S = 0.93 (loses to BM25 baseline 0.98 — see [COMPETITIVE_REALITY.md](COMPETITIVE_REALITY.md))
- **Open issues:** 10 (all tagged with target version)
- **License:** Apache-2.0, no CLA

We will not pretend more adoption than we have. We will not claim numbers we
cannot reproduce. We will not hide that BM25 outperforms us on one of two
benchmarks — see [COMPETITIVE_REALITY.md](COMPETITIVE_REALITY.md) for the
full honest assessment.

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
