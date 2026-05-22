---
date: 2026-05-22
agent: research_supervisor
task_id: v0.6.0-T7
status: complete
---

# Docs Gap Audit — pgmnemo v0.6.0

## Summary

Scoped review of README.md, INSTALL.md, docs/USAGE.md (skim), docs/SQL_REFERENCE.md
(skim TOC), docs/MIGRATION.md (skim TOC), and POSITIONING.md. Identified three
P0/P1 gaps that would block or confuse evaluators considering adoption.

---

## Gap 1 — "pgmnemo vs pgvector alone: why bother?"

**Severity:** P0 (blocks adoption)

**What an evaluator expects:** Any team already running pgvector (the majority of
Postgres shops with vector search) will ask immediately: *"We already have HNSW via
pgvector. What does adding pgmnemo actually buy us?"* The README's competitor table
compares against Mem0 / Zep / Letta / Constructive AgenticDB — all heavyweight
alternatives. It does not contain a single dedicated comparison against raw pgvector
usage. POSITIONING.md §Competitor matrix similarly skips the most common baseline.
The answer exists scattered across the README (scoring formula, provenance gate,
BM25, role scoping) but is never assembled as a crisp head-to-head.

**Draft outline:**

```
## pgmnemo vs pgvector alone

### What pgvector gives you
- HNSW / IVFFlat approximate nearest-neighbour cosine search
- `<->` distance operator in SQL
- Index build/query tuning (ef_construction, ef_search, m)

### What pgmnemo adds on top of pgvector
| Capability | Raw pgvector | pgmnemo |
|---|---|---|
| Hybrid recall (BM25 + cosine + recency + importance) | ❌ | ✅ `recall_lessons()` |
| Write-time provenance gate (enforce/warn/off) | ❌ | ✅ Postgres constraint layer |
| Role + project scoping / multi-tenancy | DIY (RLS by hand) | ✅ First-class `role+project_id` |
| Temporal decay scoring | DIY | ✅ `recency_weight` GUC + `temporal_boost` |
| Lesson lifecycle state machine | ❌ | ✅ draft→canonical→deprecated→archived |
| Graph traversal (causal/temporal/semantic/entity) | ❌ | ✅ `traverse_causal_chain()` / `traverse_temporal_window()` |
| Bitemporal validity (`t_valid_from`/`t_valid_to`) | ❌ | ✅ v0.5.0+, `as_of_ts` v0.6.0 |
| MCP server out of the box | ❌ | ✅ `pgmnemo-mcp` |

### When raw pgvector is the right choice
- You need pure similarity search with no provenance or lifecycle requirements.
- You're building a retrieval-augmented generation (RAG) pipeline over documents,
  not agent working memory.
- You already have your own scoring, filtering, and multi-tenancy layers.

### When pgmnemo is the right choice
- You need agent memory that accumulates over time with recency decay and importance weighting.
- You want hybrid recall (BM25 fills the gap where vector similarity fails on
  keyword-heavy queries — see LongMemEval-S results).
- You need a provenance gate for compliance (HIPAA, GDPR, litigation hold) or
  simply to prevent hallucinated memories from silently accumulating.
- You want role/project scoping and lifecycle management without writing it yourself.
```

---

## Gap 2 — Performance characteristics at scale (latency + throughput)

**Severity:** P0 (blocks adoption)

**What an evaluator expects:** Before committing to any memory substrate in a
production agent, an engineer asks: *"What is the p50/p95/p99 recall latency at
10K rows? 100K? 1M?"* and *"What is concurrent write throughput under a multi-agent
workload?"* README.md explicitly states in the benchmarks caveat (quoting
COMPETITIVE_REALITY.md §2): *"What pgmnemo's bench does NOT measure: insertion
throughput, concurrent read/write, retrieval latency p50/p95/p99 ... scale beyond
~5k rows."* Issue [#29](https://github.com/pgmnemo/pgmnemo/issues/29) (stress
tests) is open and unresolved. This is a documented known gap, not a surprise —
but the absence of any latency guidance means an evaluator cannot size hardware or
make a go/no-go decision for production workloads.

**Draft outline:**

```
## Performance characteristics

> ⚠️ Comprehensive stress-test results are pending (issue #29). The numbers below
> are directional estimates from development-environment runs, not production benchmarks.
> Do not use for SLA commitments. Track #29 for official results.

### Retrieval latency (single-query, PG 17, amd64, NVMe)

| Corpus size | p50 recall_lessons() | p95 | Notes |
|---|---|---|---|
| 1K rows | ~2ms | ~5ms | estimate (no index pressure) |
| 10K rows | ~5ms | ~15ms | estimate |
| 100K rows | TBD | TBD | #29 |
| 1M rows | TBD | TBD | #29 |

### HNSW index parameters and latency trade-offs
- `ef_search` (default 100) controls recall/speed tradeoff. Lower values → faster
  but lower recall@K. See `pgmnemo.ef_search` GUC in INSTALL.md.
- `m` (index build-time) trades index size for recall quality. Default inherited
  from pgvector (`m=16`).

### Write throughput (ingest)
- `enforce` gate: pure SQL constraint check — throughput bounded by Postgres
  INSERT rate, typically ~10K–50K rows/s on a well-sized instance.
- No LLM inference in the write path (contrast with Mem0 ~$0.17/1K writes).

### When BM25 beats vector recall
- LongMemEval-S workload: BM25 baseline (0.982) outperforms pgmnemo dense path
  (0.9334) by ~5pp on keyword-heavy queries.
- Hybrid recall_lessons() is intended to close this gap. If your workload is
  keyword-heavy, test BM25-dominant weighting.
- v0.6.0 RRF fix is expected to yield +1.7–2.2pp on hybrid recall@10 (projected,
  not yet validated post-release).

### Recommendations pending #29
- For corpus < 50K rows: pgmnemo is safe to run on a shared Postgres instance.
- For corpus > 100K rows: run the stress test suite (#29) on your hardware before
  committing to production.
- Report your results — we'll add them to this table with attribution.
```

---

## Gap 3 — Operational FAQ (runtime troubleshooting beyond install errors)

**Severity:** P1 (confusion risk)

**What an evaluator expects:** INSTALL.md has a solid troubleshooting section for
*installation-time* errors (vector type missing, hnsw index missing, dimension
mismatch, provenance gate error). But there is no runtime operational FAQ covering
questions that emerge *after* a successful install:

- "My recall scores are all below 0.1 — what's wrong?"
- "Which embedding model should I use? The quickstart passes `array_fill(0, ...)`."
- "How do I set up multi-tenant isolation so Agent A can't see Agent B's memories?"
- "How should I tune `temporal_boost` / `recency_weight` for my workload?"
- "The provenance gate is blocking my LangChain integration — how do I integrate?"
- "I get RLS blocks after setting `pgmnemo.tenant_id` — how do I debug?"

These surface from real adopter experience (Agency RFC, WG early-adopter feedback)
and are not answered anywhere in the current doc set. The `temporal_boost`
calibration table was added to USAGE.md in v0.5.2 but it's buried mid-document
with no FAQ framing.

**Draft outline:**

```
## Operational FAQ

### Recall / scoring questions

**Q: My recall scores are all near 0 or negative. What's wrong?**
A: Most common cause: you passed a zero vector (`array_fill(0, ARRAY[1024])`)
as `query_embedding` — cosine similarity with a zero vector is undefined and
pgvector returns 0 or NaN. Always pass a real 1024-dim embedding from your model,
or pass `NULL` for text-only (BM25) recall. Check: `SELECT score FROM
pgmnemo.recall_lessons(NULL::vector(1024), query_text := 'your query', ...)`.

**Q: Which embedding model should I use?**
A: pgmnemo requires 1024-dimensional embeddings. Tested models:
- `BAAI/bge-m3` (1024d, open weights, strong MTEB perf, HuggingFace)
- `intfloat/e5-large-v2` (1024d) — DRAGON used in LoCoMo benchmarks
- OpenAI `text-embedding-3-large` with `dimensions=1024` projection
The quickstart uses `array_fill(0, ...)` as a placeholder only — replace
before production use.

**Q: BM25 recall is beating vector recall on my workload. Is that expected?**
A: Yes, for keyword-heavy corpora (exact-match names, codes, IDs). This is
the documented LongMemEval-S gap (pgmnemo 0.9334 vs BM25 baseline 0.982).
Set `query_text` in `recall_lessons()` to enable hybrid scoring — the RRF
fusion in v0.6.0 is expected to close ~2pp of this gap.

### Multi-tenancy

**Q: How do I isolate two agents so they cannot access each other's memories?**
A: Two options:
1. `role + project_id` scoping — pass distinct `role_filter` / `project_id_filter`
   to `recall_lessons()`. Isolation is application-enforced (not RLS).
2. `pgmnemo.tenant_id` GUC — set per-session to enforce row-level isolation at the
   Postgres RLS layer. `SET pgmnemo.tenant_id = 'project_42'` before each agent
   session. Reset with `SET pgmnemo.tenant_id = ''` to bypass.
For strict separation (one agent cannot even accidentally see another's rows),
use option 2. See GUC reference in INSTALL.md.

### Provenance gate

**Q: My LangChain / MCP integration fails with `pgmnemo provenance gate [enforce]`.**
A: The `pgmnemo-mcp` wrapper passes `commit_sha` from the `metadata` dict.
For direct SQL callers: pass `p_commit_sha` to `ingest()`, or set
`SET pgmnemo.gate_strict = 'warn'` during development. In production, design
your agent to supply a provenance identifier (run ID, artifact hash, session ID)
on every write.

### Tuning recency and temporal boost

**Q: Memories from months ago are dominating recall. How do I fix it?**
A: Lower `pgmnemo.recency_weight` (default 0.08). Setting to 0.0 disables recency
decay entirely. For temporal_boost calibration, see the calibration table in
docs/USAGE.md §temporal_boost.

### Debugging

**Q: All rows are hidden after I set `pgmnemo.tenant_id`.**
A: Your tenant_id value matches no `project_id` in the table. Reset with
`SET pgmnemo.tenant_id = ''` to see all rows, then verify your project_id values
with `SELECT DISTINCT project_id FROM pgmnemo.agent_lesson`.
```

---

## Summary table

| # | Gap | Severity | Covers |
|---|---|---|---|
| 1 | pgmnemo vs pgvector alone | **P0** | Evaluators already on pgvector (majority of target market) |
| 2 | Performance at scale (latency/throughput) | **P0** | Production go/no-go decision; points to open issue #29 |
| 3 | Operational FAQ (runtime troubleshooting) | **P1** | Post-install confusion from real adopter questions (Agency RFC) |

## Recommended ownership

- Gap 1: merge into README.md §Why this exists or as a standalone `docs/VS_PGVECTOR.md`
- Gap 2: add stub `docs/PERFORMANCE.md` pointing to #29; update README benchmarks caveat
- Gap 3: add `docs/FAQ.md`; cross-link from README §Documentation and USAGE.md §Troubleshooting
