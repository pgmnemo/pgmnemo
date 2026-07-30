# pgmnemo Positioning

Your coding agent just closed a debugging session. It found the issue, fixed it, learned something. Next session: blank slate. Same mistake, same wasted turns.

pgmnemo is a PostgreSQL extension that gives coding agents persistent memory — `CREATE EXTENSION` in the database you already run. Two commands wire hooks into Claude Code, Codex CLI, or Gemini CLI. Backup is `pg_dump`. Recall is EXPLAIN-able SQL.

**Elevator pitch:** Agent memory belongs in the database, not in a third-party API. pgmnemo puts it there — hybrid vector+BM25 recall, provenance-gated writes, corpus housekeeping, and cross-model hooks, all inside your existing Postgres. No new service, no data egress, no per-write LLM cost.

---

## Batteries included: what ships in the box

| Feature | What it does | Shipped |
|---|---|---|
| `CREATE EXTENSION pgmnemo CASCADE` | Memory on. No sidecar, no API key. | v0.1.0 |
| `ingest()` | Write a lesson — SQL constraint check, no model API call on the write path. $0 LLM cost per write. | v0.1.0 |
| `recall_hybrid()` | Hybrid HNSW vector + BM25 full-text + JSONB predicate recall in one SQL plan. EXPLAIN-able. | v0.4.0 |
| `navigate_locate()` / `navigate_expand()` | Token-budget-aware ID selection — locate IDs within a character budget, expand content only when needed. | v0.8.0 |
| `reinforce()` | Outcome-weighted recall — Beta posterior confidence updates per lesson; `match_confidence [0,1]` in recall output. Default confidence boost weight is `0.0` (opt-in). | v0.7.0 / v0.13.0 |
| `consolidate()` | Near-duplicate collapsing via union-find on cosine clusters. Dry-run by default. On a 7,400-lesson real corpus: 399 clusters / 1,897 collapsible rows, largest cluster 55. | v0.14.0 |
| `undo_consolidate(canonical_id)` | Exact inverse of `consolidate()` — reversible. No competitor equivalent. | v0.14.1 |
| `classify_content_type()` | Deterministic keyword/regex classifier: `incident / decision / entity / fact / procedure`. `IMMUTABLE`, index-safe, no LLM required. | v0.14.0 |
| `reclassify_corpus()` | Batch reclassification of existing lessons. Dry-run by default. Protects curator-set types (`event`, `relation`) from overwrite. | v0.14.0 |
| `extract_sit_fp()` / `recall_situation()` | Episodic recall by situation class. Two differently-worded reports of the same failure class → same fingerprint. O(log n) expression index lookup — no embedding search. | v0.15.0 |
| `pgmnemo init claude\|codex\|gemini` | Wires session-capture and recall hooks into Claude Code, Codex CLI, or Gemini CLI automatically. | pgmnemo-mcp |
| `pgmnemo export` | Exports corpus to human-readable markdown. | pgmnemo-mcp |
| Provenance gate (`gate_strict`) | Blocks writes without `commit_sha` or `artifact_hash` at the Postgres constraint layer. Three modes: `enforce` / `warn` / `off`. No application-layer code can bypass it. | v0.1.0 |

---

## Who this is for

pgmnemo serves three segments with one product, controlled by the `gate_strict` GUC:

### 1. **Coding-agent teams** (`gate_strict = enforce`)
Agents whose memory writes must be traceable to a verifiable artifact — a `commit_sha`, `pr_id`, `ticket_id`, or `document_hash`. Every `ingest()` call is checked at the Postgres constraint layer. Hallucinated lessons from failed runs do not graduate to long-term memory.

| Segment | Typical artifact identifier | Compliance posture |
|---|---|---|
| Software dev agents | commit_sha, pr_id | Optional (change tracking) |
| RAG / document-grounded agents | document hash, chunk SHA, page revision ID | Optional (knowledge base audit) |
| Legal AI (contract review, eDiscovery) | case_id, filing_id, citation_string | **Mandatory (litigation hold, chain-of-custody)** |
| Clinical / healthcare AI | patient_record_id, clinical_note_version | **Mandatory (HIPAA, GDPR)** |
| Compliance / GRC AI | audit_event_id, control_id | **Mandatory (SOC 2, ISO 27001)** |

### 2. **Conversational & observation agents** (`gate_strict = warn` or `off`)
Agents that build memory from multi-turn dialogue or ambient observation. No provenance artifact required.

| Segment | Memory source | Gate setting |
|---|---|---|
| Chatbot long-context memory | User conversation transcript | `off` |
| Proactive / ambient agents | Synthesized from APIs, inference | `off` |
| Personal assistants | User preferences, learned behavior | `off` |
| Internal tool agents | Function calls, deployment logs | `warn` (development audit, no enforcement) |

### 3. **Backfill & bulk migration** (any mode, temporarily `gate_strict = 'warn'`)
Loading pre-existing memory or legacy system bootstrap. Set `gate_strict = 'warn'` during the backfill, emit warnings for unverified rows, then reset to production mode.

---

## Why pgmnemo exists

Agent memory belongs inside your database — not in a third-party API your agents can't inspect or explain.

**Core value propositions:**

1. **Zero new infrastructure.** `CREATE EXTENSION pgmnemo CASCADE` in your existing Postgres (17+). No sidecar daemon, no managed vector DB, no API dependency.

2. **Hybrid in-database recall.** HNSW vector search + BM25 full-text + JSONB predicate pushdown in one SQL query plan. EXPLAIN-able, regression-testable, without a service call.

3. **$0 LLM cost per write.** `ingest()` is a SQL constraint check + indexed INSERT. No model API call on the write path. Contrast with Mem0 (~$0.17 per 1,000 writes for fact extraction) or Zep (~$0.36 per 1,000 writes for contradiction resolution).

4. **Corpus housekeeping without external LLM.** `consolidate()` collapses near-duplicates; `undo_consolidate()` inverts any merge; `classify_content_type()` labels lessons by type at write time; `reclassify_corpus()` applies it to existing data. No external LLM required for any of these.

5. **Episodic recall by situation class.** `recall_situation()` retrieves prior lessons for a situation class via O(log n) fingerprint index — not text similarity. An agent that has seen a class of failure before gets the prior lessons without embedding search.

6. **Data stays in your Postgres.** No data egress. `pg_dump` backs it up. Logical replication replicates it. Role-level scoping (`role + project_id`) with optional RLS enforcement.

7. **Optional provenance gate.** Set `gate_strict = 'enforce'` — every write is checked at the constraint layer. Unverifiable facts cannot silently accumulate. The enforcement is at the Postgres constraint level; application code executing under a normal role cannot bypass it.

8. **Batteries-included cross-model hooks.** `pgmnemo init claude|codex|gemini` wires session-capture and recall hooks into the target AI CLI. Memory accumulates across sessions. No manual `memory.add()` calls required.

**Who this is *not* designed for:** If you want a fully managed SaaS product with pre-built agent integrations, Mem0 Cloud or Letta Cloud is the right choice. pgmnemo is for teams who want to own their agent infrastructure and memory substrate.

**On graph traversal:** pgmnemo includes `add_edge()` and graph traversal primitives (`graph_proximity` in `recall_hybrid`, `navigate_locate`, `navigate_expand`). The `graph_proximity_weight` GUC defaults to 0.2 but is opt-in in practice: the extension ships no automatic edge extraction, so the graph is empty unless you call `add_edge()` explicitly. We have no published benchmark showing graph-augmented recall outperforms hybrid (vector + BM25) alone. Use graph traversal when you have meaningful semantic edges; do not assume it improves recall by default.

---

## Competitor matrix

### Primary axes: Infrastructure, economics, data residency

| Dimension | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive AgenticDB |
|---|---|---|---|---|---|
| **Recall substrate** | ✅ **Hybrid in-database recall.** HNSW vectors + BM25 + JSONB pushdown in one SQL plan. EXPLAIN-able. No service call. | ❌ **Separate cloud service.** API ingests queries, returns scores. Vendor-hosted embeddings. | ⚠️ **Graphiti:** self-hosted graph service (Python). **Zep:** default SaaS cloud, self-hosted option. | ⚠️ **Separate service.** Python runtime; memory is a component, not the substrate. | ✅ **In-database.** pgvector HNSW + optional Ollama embeddings, all in SQL. |
| **Install model** | ✅ `CREATE EXTENSION pgmnemo` in your existing Postgres (17). `pgmnemo init claude\|codex\|gemini` to wire hooks. | ❌ SaaS API endpoint (`https://api.mem0.com`). Proprietary vendor dependency. | ⚠️ **Graphiti:** `pip install graphiti-core` + graph DB (self-hosted). **Zep:** Cloud SaaS or self-hosted. | ⚠️ `pip install letta-core` (self-hosted Python) or Letta Cloud SaaS. | ✅ `pgpm install constructive_agenticdb` in your Postgres. Native extension. |
| **LLM cost per write** | ✅ **$0.** Provenance gate is a SQL constraint check (zero model inference). | ❌ **~$0.17 per 1,000 writes.** GPT-3.5-mini fact extraction on every ingest. | ❌ **~$0.36 per 1,000 writes** (post-v0.29). LLM-powered contradiction detection on graph updates. | ✅ **$0 incremental.** Memory write cost is bundled with the agent turn already paying for inference. | ✅ **$0.** Local Ollama embeddings; no API calls. |
| **Data residency / self-hosted** | ✅ **Your Postgres, your VPC.** No data egress. HIPAA-aligned by architecture. | ❌ **Mem0 infrastructure.** Data hosted on `us-west-2`. Egress fees, latency. | ⚠️ **Zep Cloud:** vendor; **Graphiti:** self-hosted. | ⚠️ **Self-hosted:** your infrastructure. **Letta Cloud:** vendor infrastructure. | ✅ **Your Postgres.** Encryption at rest, backup fully under your control. |
| **Corpus housekeeping** | ✅ `consolidate()` / `undo_consolidate()`, `classify_content_type()`, `reclassify_corpus()` — no external LLM. | ✅ Built-in fact extraction and deduplication (LLM-powered; per-write cost). | ✅ LLM-powered contradiction resolution (Graphiti). | ⚠️ Block-level append-only; no dedup. | ❌ Not documented. |
| **Episodic recall** | ✅ `recall_situation()` — situation fingerprint index, O(log n), no embedding search. | ❌ No situational fingerprinting. | ⚠️ Graph edges capture some temporal/causal context. | ❌ No situational fingerprinting. | ❌ Not documented. |
| **Cross-model hooks** | ✅ Claude Code, Codex CLI, Gemini CLI (`pgmnemo init`). | ⚠️ LangChain/CrewAI integrations; not CLI hook-packs. | ⚠️ Python SDK integrations. | ✅ Letta framework integrations. | ❌ Not documented. |

### Optional tier-2: Compliance enforcement

| Dimension | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive |
|---|---|---|---|---|---|
| **Write-time provenance gate (3 modes)** | ✅ `enforce` / `warn` / `off` via GUC. Enforced at Postgres constraint layer. Bypass requires SUPERUSER. | ❌ No gate. `metadata=` is a post-hoc audit log, not a write veto. | ❌ Episode references are descriptive but not a write-time veto. | ❌ `core_memory_append()` is unconditional. No quality gate. | ❌ No provenance gate. |
| **Temporal versioning** | ✅ `created_at` + bitemporal (`t_valid_from`/`t_valid_to`, `content_hash`). | ✅ Yes (managed cloud). Auto-tracked. | ✅ Bitemporal edges at graph; LLM-driven contradiction resolution. | ⚠️ Limited (block-level append-only). | ❌ Not public. |

### Target segments (ICP: what should use what)

| Use Case | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive |
|---|---|---|---|---|---|
| **Coding-agent teams with Postgres** | ✅ **Best-fit.** `pgmnemo init claude\|codex\|gemini`. Cross-model hooks + in-database memory. | ⚠️ OK (SaaS; no cross-model CLI hooks). | ⚠️ OK (no CLI hooks). | ⚠️ OK (agent framework, not a CLI hook-pack). | ✅ OK (Postgres extension). |
| **Citation-grounded + compliance required** (Legal, Healthcare, GRC) | ✅ **Best-fit.** `gate_strict='enforce'`. Write-time rejection at DB layer. | ⚠️ OK (no enforcement; audit logs optional). | ⚠️ OK (graph is nice; no enforcement). | ⚠️ OK (no enforcement). | ⚠️ OK (no enforcement). |
| **Conversational agents / chatbots** | ✅ **Best-fit.** Set `gate_strict='off'`. In-database recall. | ✅ **Best-fit.** Purpose-built SaaS. 80K+ developers. Easy integrations. | ✅ OK. Graph structure is elegant. | ✅ OK. Part of agent framework. | ✅ OK. |
| **Backfill & migration** | ✅ **Best-fit.** Temporarily set `gate_strict='warn'`. | ✅ OK. | ✅ OK. | ✅ OK. | ✅ OK. |

### Production maturity

| Metric | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive |
|---|---|---|---|---|---|
| **Production deployments** | ⚠️ 1 external early-adopter (growing). In production at one engineering team (8-person, daily use). | ✅ 186M+ API calls/month (2025). 80K+ registered developers. 19+ enterprise customers. | ✅ Zep: enterprise tier. Graphiti: growing OSS community. | ✅ 1M+ agents in production (Bilt, Aurora Postgres backend). | ⚠️ Not publicly documented. |
| **License** | ✅ Apache 2.0. | ❌ Proprietary SaaS. | ✅ Apache 2.0 (Graphiti) + Zep Cloud SaaS. | ✅ MIT (Letta) + Letta Cloud SaaS. | ✅ MIT. |
| **OSS governance** | ✅ Public GitHub, DCO contributions. | ❌ Closed-source SaaS. | ✅ Apache 2.0 Graphiti is fully open. | ✅ MIT Letta is fully open. | ✅ Public GitHub (if available). |

---

## Decision framework

**Use pgmnemo if:**
- Your Postgres is your primary datastore and you want memory in the same database (zero new service).
- You're running Claude Code, Codex CLI, or Gemini CLI and want cross-model hooks with two commands (`pip install pgmnemo-mcp && pgmnemo init claude`).
- You need to avoid per-write LLM costs (critical for high-velocity agents).
- You need corpus housekeeping without an external LLM — `consolidate()` collapses near-duplicates, `classify_content_type()` labels by type, `undo_consolidate()` is the safety net.
- You want episodic recall by situation class (`recall_situation()`), not just text similarity.
- You have compliance requirements (HIPAA, GDPR, litigation hold) — `gate_strict='enforce'` for write-time provenance gates at the constraint layer.
- You want hybrid recall (vector + BM25 + JSONB) in one SQL plan, EXPLAIN-able and regression-testable.
- You want data residency under your control (no vendor lock-in, `pg_dump` backup, logical replication).

**Use Mem0 if:**
- You prefer a fully managed SaaS product with zero infrastructure overhead.
- You're OK with vendor lock-in and per-write LLM costs (~$0.17 per 1K writes).
- You want multi-agent cloud sync (shared memory across multiple agent instances).
- You want pre-built integrations (LangChain, LlamaIndex, CrewAI, etc.).

**Use Zep/Graphiti if:**
- You want structured knowledge-graph memory with rich edge semantics (semantic, temporal, causal, entity).
- You prefer self-hosted (Graphiti) with graph-native contradiction detection.
- You don't mind per-write LLM costs for contradiction resolution.

**Use Letta if:**
- You want an end-to-end agent framework, not just memory.
- Memory is one component of the agent, not your primary substrate.

**Use Constructive AgenticDB if:**
- You want pure vector memory in Postgres (no other frills).
- You don't need compliance gates, corpus housekeeping, or hybrid recall.
- You prefer a minimal, vector-only approach.

---

## Emerging competitors (June 2026)

| Dimension | **GBrain** | **Memoir** | **agentmemory** | **Odysseus** |
|---|---|---|---|---|
| **What it is** | Markdown knowledge graph (PGLite/Postgres WASM) | Taxonomy-structured path-based recall (ProllyTreeStore) | Hybrid BM25+vector for coding agents (SQLite) | Self-hosted AI workspace; ChromaDB session recall |
| **License** | MIT | Apache 2.0 | MIT | MIT |
| **Install model** | `bun install gbrain` (PGLite embedded) | `pip install memoir` + Claude Code plugin | `npm install agentmemory` | Docker Compose (full workspace) |
| **LLM cost per write** | ✅ $0 (regex graph extraction) | ⚠️ ~$0 (pattern match; LLM fallback rare) | ❌ Non-zero (background compression per observation) | Unknown (ChromaDB embeddings) |
| **Recall substrate** | HNSW vectors + regex-typed graph edges | Path-based exact match + tiered semantic drill-down | BM25 + vector hybrid (SQLite FTS5) | ChromaDB vector only |
| **Provenance gate** | ❌ None | ❌ None (SHA-256 content hash for versioning) | ❌ None | ❌ None |
| **Standard benchmarks** | BrainBench only (own corpus) | None published | LongMemEval-S R@10 98.6% | None |
| **Production maturity** | 146K pages in founder's personal brain | Alpha | Coding agent community adoption | 67K stars; session memory only |
| **pgmnemo advantage** | Hybrid recall, provenance gate, corpus housekeeping, standard benchmarks | In-database substrate, hybrid recall, academic benchmarks, production fleet evidence | Concurrent writes (Postgres vs SQLite), RLS, provenance, EXPLAIN-able ranking, corpus housekeeping | Not comparable — different category |

**Use GBrain if:** your use case is a personal knowledge graph from Markdown files and you want zero-config Postgres (PGLite). Not for multi-agent fleet memory.

**Use Memoir if:** you want taxonomy-organized memory with Git-like versioning and deterministic path-based retrieval. Alpha-stage; no standard recall benchmarks yet.

**Use agentmemory if:** you want drop-in memory for a single coding agent (Claude Code, Cursor) with zero-config auto-capture hooks. Accept SQLite single-writer limitation and per-observation LLM cost.

**Do not treat Odysseus as a memory competitor.** It is a self-hosted AI workspace (ChatGPT alternative). Memory is a bolted-on ChromaDB session feature, not a substrate.

---

## What would falsify our claims

| Claim | Falsification condition |
|---|---|
| **"Hybrid in-database recall (vector + BM25 + JSONB)"** | `pgmnemo.recall_hybrid()` returns results computed via an external service call (vectors, BM25, or scoring executed outside Postgres) |
| **"Zero LLM cost per write"** | A standard `pgmnemo.ingest()` call triggers any embedding generation, fact extraction, or language model inference as part of the write path (under any gate mode: `enforce`, `warn`, or `off`) |
| **"No extra service required"** | pgmnemo requires a sidecar daemon, embedded runtime, or external API call to initialize or operate after `CREATE EXTENSION pgmnemo CASCADE` |
| **"Write-time provenance enforcement (gate_strict='enforce')"** | With `gate_strict='enforce'`, a standard `pgmnemo.ingest()` call succeeds (row reaches the heap) without either `commit_sha` or `artifact_hash` supplied, unless the caller has database SUPERUSER role |
| **"Bypass-proof enforcement from application layer"** | Application code executing under normal role writes a provenance-free row with `gate_strict='enforce'` without triggering an RLS policy error |
| **"consolidate() / undo_consolidate()"** | `undo_consolidate(canonical_id)` fails to restore the canonical lesson and its cluster members to `is_active = TRUE` after a `consolidate()` run, or `consolidate()` fails to produce the corpus report on a 7,400-row test fixture |
| **"recall_situation() O(log n) lookup"** | `recall_situation()` performs a sequential scan on `agent_lesson` (visible via `EXPLAIN` with `enable_seqscan = OFF`) rather than using the `ix_pgmnemo_sit_fp_active` expression index |
| **"Cross-model hooks (Claude Code / Codex / Gemini)"** | `pgmnemo init claude` (or `codex` or `gemini`) fails to write a valid hook configuration into `.claude/` (or `.codex/` or `.gemini/`) in a project directory where those directories exist |
| **"Configurable gate (enforce/warn/off modes)"** | The GUC `pgmnemo.gate_strict` fails to control `ingest()` behavior — e.g., `enforce` mode fails to reject unverified writes, or `off` mode blocks writes |
| **"Works for conversational agents (mode 'off')"** | Conversational agent memory writes (no provenance artifact) fail or error with `gate_strict='off'` after `CREATE EXTENSION pgmnemo CASCADE` and schema init |
| **Published recall@10 figures** | A reproducible re-run of the bench scripts on the published corpus snapshot (following `docs/BENCHMARK_PROTOCOL.md`) produces a value outside the published 95% confidence interval |
| **Competitor facts** | Any published competitor attribute (license, LLM cost, architecture) contradicts official public documentation — correct immediately and publish a correction note with date and evidence link |

---

## Benchmark honesty

pgmnemo publishes numbers with confidence intervals and mandatory negative cells. Full protocol: [docs/BENCHMARK_PROTOCOL.md](docs/BENCHMARK_PROTOCOL.md).

| Corpus | recall@10 | Honest note |
|---|---|---|
| LoCoMo (ACL 2024) | 0.8409 | Session-level; 22× smaller search space than paper Table 3. Turn-level apples-to-apples: recall@5 = 0.302 vs paper DRAGON baseline 0.225 (+7.7pp) |
| LongMemEval-S (ICLR 2025) | 0.9604 | Gap to BM25 baseline (0.982) narrowed from −5pp (v0.5.x) to −2.2pp (v0.6.2 RRF Fix-A, p=0.017). We still lose to a 50-line BM25 script. |
| Production corpus (N=1,060, external adopter) | 0.5745 | Real-world agent memory; leave-one-out self-retrieval |

**On the Agency case study (−68% turns):** agents at one engineering team used 68% fewer turns on runs *where memory fired a relevant hit*. This is significant on that slice. Averaged across *all* runs the effect washes out — memory only helps when it has something relevant to say. We do not headline "−68% fewer turns" without this qualification.

We publish where we lose. A benchmark that shows only wins is indistinguishable from cherry-picking. Full honest self-assessment: [docs/COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md).

---

*Apache 2.0 — [github.com/pgmnemo/pgmnemo](https://github.com/pgmnemo/pgmnemo)*
