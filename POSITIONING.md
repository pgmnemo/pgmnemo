# pgmnemo Positioning

## The problem

Your coding agent closes a debugging session. It found the issue, fixed it, learned something. Next session: blank slate. Same mistake, same wasted turns.

This happens because agent memory lives in the context window. When the session ends, the memory is gone.

## What pgmnemo does about it

pgmnemo is a PostgreSQL extension. `CREATE EXTENSION pgmnemo CASCADE` in the database you already run — memory is on. Two commands wire hooks into Claude Code, Codex CLI, or Gemini CLI. Backup is `pg_dump`. Recall is EXPLAIN-able SQL. No new service, no data egress, no per-write LLM cost.

### See it work (live transcript, July 2026)

**Session 1** — agent writes what it learned:

```sql
SELECT pgmnemo.ingest(
  'developer', 99, 'connection-pooling',
  'When PgBouncer runs in transaction mode, prepared statements fail
   silently. Switch to session mode, or disable the statement cache.',
  4, NULL, 'demo_readme_proof'
);
-- Result: 45087
```

**Session 2** — different agent, fresh context, same problem:

```sql
SELECT lesson_id, score, lesson_text FROM pgmnemo.recall_lessons(
  query_embedding := NULL::vector, k := 3,
  role_filter := 'developer',
  query_text := 'prepared statements broken with pgbouncer'
);

  [1] id=45087  score=0.0500
      When PgBouncer runs in transaction mode, prepared statements fail
      silently. Switch to session mode, or disable the statement cache.
```

The lesson from Session 1 surfaces as the top result. The second agent skips the debugging cycle.

---

## What ships in the box

| Feature | What it does | Shipped |
|---|---|---|
| `CREATE EXTENSION pgmnemo CASCADE` | Memory on. No sidecar, no API key. | v0.1.0 |
| `ingest()` | Write a lesson — SQL constraint check, no model API call. $0 LLM cost per write. | v0.1.0 |
| `recall_hybrid()` | Hybrid HNSW vector + BM25 + JSONB recall in one SQL plan. EXPLAIN-able. | v0.4.0 |
| `consolidate()` / `undo_consolidate()` | Near-duplicate collapsing via union-find. Dry-run by default. Reversible. | v0.14.0 / v0.14.1 |
| `classify_content_type()` | Deterministic classifier: incident / decision / entity / fact / procedure. No LLM. | v0.14.0 |
| `extract_sit_fp()` / `recall_situation()` | Episodic recall by situation class. O(log n) index lookup — no embedding search. | v0.15.0 |
| `reinforce()` | Outcome-weighted recall — Beta posterior confidence. `match_confidence [0,1]`. | v0.7.0 / v0.13.0 |
| `navigate_locate()` / `navigate_expand()` | Token-budget-aware ID selection. | v0.8.0 |
| `reclassify_corpus()` | Batch reclassification. Dry-run by default. Protects curator-set types. | v0.14.0 |
| `pgmnemo init claude\|codex\|gemini` | Wires session-capture and recall hooks automatically. | pgmnemo-mcp |
| `pgmnemo export` | Exports corpus to human-readable markdown. | pgmnemo-mcp |
| Provenance gate (`gate_strict`) | Blocks writes without `commit_sha` or `artifact_hash` at Postgres constraint layer. Three modes: `enforce` / `warn` / `off`. | v0.1.0 |

---

## Who this is for

pgmnemo serves three segments with one product, controlled by the `gate_strict` GUC:

### 1. Coding-agent teams (`gate_strict = enforce`)
Agents whose memory writes must be traceable to a verifiable artifact — a `commit_sha`, `pr_id`, `ticket_id`, or `document_hash`. Every `ingest()` call is checked at the Postgres constraint layer.

| Segment | Typical artifact | Compliance posture |
|---|---|---|
| Software dev agents | commit_sha, pr_id | Optional (change tracking) |
| RAG / document-grounded agents | document hash, chunk SHA | Optional (knowledge base audit) |
| Legal AI (contract review, eDiscovery) | case_id, filing_id | **Mandatory (litigation hold)** |
| Clinical / healthcare AI | patient_record_id | **Mandatory (HIPAA, GDPR)** |
| Compliance / GRC AI | audit_event_id, control_id | **Mandatory (SOC 2, ISO 27001)** |

### 2. Conversational & observation agents (`gate_strict = warn` or `off`)
Agents that build memory from multi-turn dialogue or ambient observation. No provenance artifact required.

| Segment | Memory source | Gate setting |
|---|---|---|
| Chatbot long-context memory | Conversation transcript | `off` |
| Proactive / ambient agents | Synthesized from APIs | `off` |
| Personal assistants | User preferences | `off` |
| Internal tool agents | Function calls, deploy logs | `warn` |

### 3. Backfill & bulk migration (any mode)
Loading pre-existing memory. Set `gate_strict = 'warn'` during backfill, emit warnings for unverified rows, then reset to production mode.

---

## Honest limits

### The −68% turns result has a caveat

Agents at one engineering team used 68% fewer turns on runs where memory fired a relevant hit. This is significant on that slice. Averaged across *all* runs the effect washes out — memory only helps when it has something relevant to say. We do not headline "−68% fewer turns" without this qualification.

### The graph layer does not improve recall

pgmnemo includes `add_edge()` and graph traversal primitives. The `graph_proximity_weight` GUC defaults to 0.2. We have no published benchmark showing graph-augmented recall outperforms hybrid (vector + BM25) alone. The graph layer ships for dependency tracking and causal chains, not as a recall quality lever.

### BM25 baseline still wins on LongMemEval-S

| Benchmark | pgmnemo recall@10 | Comparison |
|---|---|---|
| LongMemEval-S (ICLR 2025) | 0.9604 | BM25 baseline = 0.982 (−2.2pp gap) |
| LoCoMo (ACL 2024) | 0.8409 (session-level) | 22× smaller search space than paper Table 3 |
| LoCoMo turn-level | recall@5 = 0.302 | Paper DRAGON = 0.225 (+7.7pp) |
| Production corpus (N=1,060) | 0.5745 | Leave-one-out self-retrieval |

We publish where we lose. Full honest self-assessment: [docs/COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md). Benchmark protocol: [docs/BENCHMARK_PROTOCOL.md](docs/BENCHMARK_PROTOCOL.md).

---

## Competitor matrix

### Primary axes: Infrastructure, economics, data residency

| Dimension | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive AgenticDB |
|---|---|---|---|---|---|
| **Recall substrate** | Hybrid in-database (HNSW + BM25 + JSONB). EXPLAIN-able. | Separate cloud service. Vendor-hosted embeddings. | Graphiti: self-hosted graph. Zep: SaaS or self-hosted. | Separate Python runtime. | In-database (pgvector HNSW + Ollama). |
| **Install model** | `CREATE EXTENSION pgmnemo` + `pgmnemo init claude\|codex\|gemini`. | SaaS API endpoint. | Graphiti: `pip install graphiti-core` + graph DB. Zep: Cloud or self-hosted. | `pip install letta-core` or Letta Cloud. | `pgpm install constructive_agenticdb`. |
| **LLM cost per write** | $0. SQL constraint check only. | ~$0.17/1K writes (GPT extraction). | ~$0.36/1K writes (contradiction detection). | $0 incremental (bundled with agent turn). | $0 (local Ollama). |
| **Data residency** | Your Postgres, your VPC. No data egress. | Vendor infrastructure (us-west-2). | Zep Cloud: vendor. Graphiti: self-hosted. | Self-hosted or Letta Cloud. | Your Postgres. |
| **Corpus housekeeping** | `consolidate()` / `undo_consolidate()`, `classify_content_type()` — no external LLM. | Built-in (LLM-powered; per-write cost). | LLM-powered contradiction resolution (Graphiti). | Block-level append-only; no dedup. | Not documented. |
| **Episodic recall** | `recall_situation()` — fingerprint index, O(log n). | No situational fingerprinting. | Graph edges capture some temporal context. | No. | No. |
| **Cross-model hooks** | Claude Code, Codex CLI, Gemini CLI. | LangChain/CrewAI integrations. | Python SDK. | Letta framework. | Not documented. |

### Compliance enforcement

| Dimension | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive |
|---|---|---|---|---|---|
| **Provenance gate** | `enforce` / `warn` / `off` via GUC. Postgres constraint layer. | No gate. Metadata is post-hoc audit. | Descriptive episode references, not a write veto. | Unconditional `core_memory_append()`. | No. |
| **Temporal versioning** | Bitemporal (`t_valid_from`/`t_valid_to`, `content_hash`). | Auto-tracked (managed cloud). | Bitemporal edges + LLM contradiction resolution. | Block-level append-only. | Not public. |

### Production maturity

| Metric | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive |
|---|---|---|---|---|---|
| **Deployments** | 1 external early-adopter + 1 engineering team (8-person, daily use). | 186M+ API calls/month. 80K+ developers. | Zep: enterprise tier. Graphiti: growing OSS. | 1M+ agents in production. | Not publicly documented. |
| **License** | Apache 2.0. | Proprietary SaaS. | Apache 2.0 (Graphiti) + Zep Cloud. | MIT (Letta) + Letta Cloud. | MIT. |

---

## Emerging competitors (June 2026)

| Dimension | **GBrain** | **Memoir** | **agentmemory** | **Odysseus** |
|---|---|---|---|---|
| **What it is** | Markdown knowledge graph (PGLite/Postgres WASM) | Taxonomy-structured path-based recall | Hybrid BM25+vector for coding agents (SQLite) | Self-hosted AI workspace; ChromaDB session recall |
| **License** | MIT | Apache 2.0 | MIT | MIT |
| **Install model** | `bun install gbrain` (PGLite embedded) | `pip install memoir` + Claude Code plugin | `npm install agentmemory` | Docker Compose (full workspace) |
| **Standard benchmarks** | BrainBench only (own corpus) | None published | LongMemEval-S R@10 98.6% | None |
| **pgmnemo advantage** | Hybrid recall, provenance gate, corpus housekeeping, standard benchmarks | In-database substrate, hybrid recall, academic benchmarks, production evidence | Concurrent writes (Postgres vs SQLite), RLS, provenance, EXPLAIN-able ranking | Not comparable — different category |

---

## Decision framework

**Use pgmnemo if:**
- Your Postgres is your primary datastore and you want memory in the same database.
- You run Claude Code, Codex CLI, or Gemini CLI and want cross-model hooks.
- You need $0 LLM cost per write.
- You need corpus housekeeping without an external LLM.
- You want episodic recall by situation class.
- You have compliance requirements and need write-time provenance gates.
- You want EXPLAIN-able hybrid recall.

**Use Mem0 if:**
- You prefer fully managed SaaS with zero infrastructure overhead.
- You want multi-agent cloud sync and pre-built integrations.

**Use Zep/Graphiti if:**
- You want structured knowledge-graph memory with rich edge semantics.
- You prefer self-hosted (Graphiti) with graph-native contradiction detection.

**Use Letta if:**
- You want an end-to-end agent framework, not just memory.

**Use Constructive AgenticDB if:**
- You want pure vector memory in Postgres, minimal approach.

**Who this is not for:** If you want a fully managed SaaS product with pre-built agent integrations, Mem0 Cloud or Letta Cloud is the right choice. pgmnemo is for teams who want to own their agent infrastructure and memory substrate.

---

## What would falsify our claims

| Claim | Falsification condition |
|---|---|
| **"Hybrid in-database recall"** | `recall_hybrid()` returns results computed via an external service call |
| **"Zero LLM cost per write"** | A standard `ingest()` call triggers any model inference on the write path |
| **"No extra service required"** | pgmnemo requires a sidecar or external API call to operate after `CREATE EXTENSION` |
| **"Write-time provenance enforcement"** | With `gate_strict='enforce'`, `ingest()` succeeds without `commit_sha` or `artifact_hash` for a normal role |
| **"consolidate() / undo_consolidate()"** | `undo_consolidate()` fails to restore cluster members after `consolidate()` |
| **"recall_situation() O(log n)"** | `recall_situation()` performs a sequential scan (visible via EXPLAIN) |
| **"Cross-model hooks"** | `pgmnemo init claude` fails to write valid hook configuration |
| **Published recall@10 figures** | A reproducible re-run produces a value outside the published 95% confidence interval |
| **Competitor facts** | Any competitor attribute contradicts official public documentation — correct immediately |

---

*Apache 2.0 — [github.com/pgmnemo/pgmnemo](https://github.com/pgmnemo/pgmnemo)*
