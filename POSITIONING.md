# pgmnemo Positioning

**Postgres extension for agent memory: single-plan multimodal recall, token-budget navigation, zero-cost writes, optional provenance enforcement.**

*One `CREATE EXTENSION` command. Vector + BM25 + graph proximity + JSONB pushdown in one SQL query plan. Zero LLM inference per write. Token-economy navigation: locate IDs within a budget, expand content on demand. Provenance gate configurable via GUC: `enforce` / `warn` / `off`.*

> In-database agent memory substrate. Self-hosted. No new service. No vendor lock-in. EXPLAIN-able ranking.

---

## Who this is for

pgmnemo serves three segments with one product, controlled by the `gate_strict` GUC:

### 1. **Citation-grounded agents** (`gate_strict = enforce`)
Agents whose memory writes are traceable to independently-verifiable artifacts. Every `ingest()` call requires a `commit_sha`, `document_hash`, `ticket_id`, `patient_record_id`, or equivalent. Writes without provenance are rejected at the Postgres constraint layer — application code cannot bypass it.

| Segment | Typical artifact identifier | Compliance posture |
|---|---|---|---|
| RAG / document-grounded agents | document hash, chunk SHA, page revision ID | Optional (knowledge base audit) |
| Customer support agents | ticket_id, conversation_id | Optional |
| Clinical / healthcare AI | patient_record_id, clinical_note_version | **Mandatory (HIPAA, GDPR)** |
| Legal AI (contract review, eDiscovery) | case_id, filing_id, citation_string | **Mandatory (litigation hold, chain-of-custody)** |
| Software dev agents | commit_sha, pr_id | Optional (change tracking) |
| Compliance / GRC AI | audit_event_id, control_id | **Mandatory (SOC 2, ISO 27001, audit trail)** |

### 2. **Conversational & observation agents** (`gate_strict = warn` or `off`)
Agents that build memory from multi-turn dialogue, sensor fusion, or ambient environment observation. No provenance artifact required. Set `gate_strict = 'off'` for unconstrained writes; set `'warn'` for development audit logs without blocking writes.

| Segment | Memory source | Gate setting |
|---|---|---|
| Chatbot long-context memory | User conversation transcript | `off` (optional artifact logging) |
| Proactive agents / ambient intelligence | Synthesized from sensors, APIs, or inference | `off` (facts don't require source cite) |
| Personal assistants | User preferences, learned behavior, chitchat context | `off` (no audit required) |
| Internal tool agents | Function calls, deployment logs, synthesis | `warn` (development audit, no enforcement) |

### 3. **Backfill & bulk migration** (any mode, temporarily `gate_strict = 'warn'`)
Loading pre-existing memory, data migration, or legacy system bootstrap. Set `gate_strict = 'warn'` during the backfill, emit warnings for unverified rows, then reset to your production mode once backfill completes.

---

## Why pgmnemo exists

Agents need persistent memory in their control — not in a third-party API. pgmnemo puts memory where it belongs: inside your Postgres database.

**Core value proposition:**

1. **In-database recall, zero new infrastructure.** Vector search + BM25 hybrid scoring in pure SQL. No sidecar service, no managed vector DB, no API dependency. `CREATE EXTENSION pgmnemo` and you're done.

2. **Zero LLM cost per write.** Memory ingest is a SQL constraint check, not a model API call. Contrast with Mem0 (~$0.17 per 1,000 writes for fact extraction) or Zep (~$0.36 per 1,000 writes for contradiction resolution). pgmnemo's gate is compute-only.

3. **Data stays in your Postgres.** No data egress, no SaaS vendor lock-in, no cloud billing surprises. Control your own RLS, backup, encryption. HIPAA-aligned by architecture, not by policy.

4. **Optional compliance gate for citation-grounded agents.** When you need it, set `gate_strict = 'enforce'` — then every memory write is checked at the Postgres constraint layer before it commits. Hallucinated facts cannot silently accumulate. Unerasable audit trail in your database.

**Who this is *not* designed for:** If you want a fully managed SaaS product with pre-built agent integrations, Mem0 Cloud or Letta Cloud is the right choice. pgmnemo is for teams who want to own their agent infrastructure.

**The differentiator claim:** pgmnemo is the only Postgres extension that fuses vector (HNSW), BM25 full-text, graph-edge proximity, and JSONB metadata filtering into a **single SQL query plan** — with optional write-time provenance enforcement at the database constraint layer. The execution plan is inspectable via EXPLAIN, ranking is regression-testable with SQL, and no data leaves your database. This makes it simultaneously the simplest agent memory layer for conversational agents AND the only provenance-gated, EXPLAIN-able, token-economy-aware option for production agent systems.

---

## Competitor matrix

### Primary Axes: Infrastructure, Economics, Data Residency

| Dimension | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive AgenticDB |
|---|---|---|---|---|---|
| **Recall substrate** | ✅ **Single-plan multimodal fusion.** HNSW vectors + BM25 + graph proximity + JSONB pushdown + relational, all in one SQL query plan. EXPLAIN-able. No service call. | ❌ **Separate cloud service.** API ingests queries, returns scores. Vendor-hosted embeddings. | ⚠️ **Graphiti:** self-hosted graph service (Python). **Zep:** default SaaS cloud, self-hosted option. | ⚠️ **Separate service.** Python runtime; memory is a component, not the substrate. | ✅ **In-database.** pgvector HNSW + optional Ollama embeddings, all in SQL. |
| **Install model** | ✅ `CREATE EXTENSION pgmnemo` in your existing Postgres (14–17). Fully portable, no lock-in. | ❌ SaaS API endpoint (`https://api.mem0.com`). Proprietary vendor dependency. | ⚠️ **Graphiti:** `pip install graphiti-core` + graph DB (self-hosted). **Zep:** Cloud SaaS or self-hosted. | ⚠️ `pip install letta-core` (self-hosted Python) or Letta Cloud SaaS. | ✅ `pgpm install constructive_agenticdb` in your Postgres. Native extension. |
| **LLM cost per write** | ✅ **$0.** Provenance gate is a SQL constraint check (zero model inference). | ❌ **~$0.17 per 1,000 writes.** GPT-3.5-mini fact extraction on every ingest. | ❌ **~$0.36 per 1,000 writes** (post-v0.29). LLM-powered contradiction detection on graph updates. | ✅ **$0 incremental.** Memory write cost is bundled with the agent turn already paying for inference. | ✅ **$0.** Local Ollama embeddings; no API calls. |
| **Data residency / self-hosted** | ✅ **Your Postgres, your VPC.** No data egress. HIPAA-aligned by architecture (single-tenant, encrypted at rest, unmatched audit trail). | ❌ **Mem0 infrastructure.** Data hosted on `us-west-2`. Egress fees, latency, no zero-trust model. | ⚠️ **Zep Cloud:** vendor; **Graphiti:** self-hosted. Graphiti gives you data control, Zep does not. | ⚠️ **Self-hosted:** your infrastructure. **Letta Cloud:** vendor infrastructure. You choose. | ✅ **Your Postgres.** Encryption at rest, backup, disaster recovery fully under your control. |

### Optional Tier-2: Compliance Enforcement

| Dimension | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive |
|---|---|---|---|---|---|
| **Write-time provenance gate (3 modes)** | ✅ `enforce` / `warn` / `off` via GUC. RLS-enforced at Postgres constraint layer. Bypass requires SUPERUSER. | ❌ No gate. `metadata=` is a post-hoc audit log, not a write veto. | ❌ Episode references are descriptive (who authored?) but not a write-time veto. No mandatory provenance. | ❌ `core_memory_append()` is unconditional. No quality gate. Audit optional. | ❌ No provenance gate. |
| **Temporal versioning** | ✅ `created_at` (v0.4) + bitemporal (`t_valid_from`/`t_valid_to`, `content_hash`). `mem.as_of(timestamp)` targeting v0.5.0. | ✅ Yes (managed cloud). Auto-tracked. | ✅ Bitemporal edges at graph; LLM-driven contradiction resolution. | ⚠️ Limited (block-level append-only). | ❌ Not public. |

### Target Segments (ICP: What should use what)

| Use Case | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive |
|---|---|---|---|---|---|
| **Citation-grounded + compliance required** (Legal, Healthcare, GRC) | ✅ **Best-fit.** Set `gate_strict='enforce'`. Write-time rejection at DB layer. | ⚠️ OK (no enforcement; audit logs are optional). | ⚠️ OK (graph is nice; no enforcement). | ⚠️ OK (no enforcement; audit optional). | ⚠️ OK (no enforcement). |
| **Conversational agents** (Chatbots, personal assistants, preference tracking) | ✅ **Best-fit.** Set `gate_strict='off'`. No artifact required. In-database recall. | ✅ **Best-fit.** Purpose-built SaaS. 80K+ developers. Easy integrations. | ✅ OK. Graph structure is elegant. | ✅ OK. Part of agent framework. | ✅ OK. |
| **Observation/ambient agents** (Sensor fusion, multi-turn synthesis) | ✅ **Best-fit.** Set `gate_strict='off'`. Synthesized facts, no artifact required. | ✅ OK. | ✅ **Strong-fit.** Graph structure maps sensor → inference → belief. | ✅ OK. | ✅ OK. |
| **Backfill & migration** (Legacy data, system bootstrap) | ✅ **Best-fit.** Temporarily set `gate_strict='warn'`. Emit logs, no enforcement. | ✅ OK. | ✅ OK. | ✅ OK. | ✅ OK. |

### Production Maturity

| Metric | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive |
|---|---|---|---|---|---|
| **Production deployments** | ⚠️ 1 external early-adopter (growing). | ✅ 186M+ API calls/month (2025). 80K+ registered developers. 19+ enterprise customers. | ✅ Zep: enterprise tier. Graphiti: growing OSS community. | ✅ 1M+ agents in production (Bilt, Aurora Postgres backend). | ⚠️ Not publicly documented. |
| **License** | ✅ Apache 2.0 (fully unrestricted). | ❌ Proprietary SaaS. | ✅ Apache 2.0 (Graphiti) + Zep Cloud SaaS. | ✅ MIT (Letta) + Letta Cloud SaaS. | ✅ MIT (fully unrestricted). |
| **OSS governance** | ✅ Public GitHub, DCO contributions. | ❌ Closed-source SaaS. | ✅ Apache 2.0 Graphiti is fully open. Zep less transparent. | ✅ MIT Letta is fully open. | ✅ Public GitHub (if available). |

---

### Decision Framework

**Use pgmnemo if:**
- Your Postgres is your primary datastore and you want memory in the same database (zero new service).
- You need to avoid per-write LLM costs (critical for high-velocity agents).
- You have compliance requirements (HIPAA, GDPR, litigation hold) — set `gate_strict='enforce'` for write-time provenance gates.
- You want single-plan multimodal recall (vectors + BM25 + graph proximity + JSONB pushdown in one SQL query plan), EXPLAIN-able and regression-testable.
- You need token-budget-aware retrieval — `navigate_locate()` + `navigate_expand()` let you control exactly how many characters your agent receives.
- You want outcome-learning feedback — `reinforce()` adjusts per-lesson confidence and `match_confidence` gives your agent an interpretable quality signal.
- You want data residency under your control (no vendor lock-in).

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
- You don't need compliance gates or hybrid recall (BM25 + vectors).
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
| **pgmnemo advantage** | Multimodal fusion, provenance gate, token-economy navigation, standard benchmarks | In-database substrate, hybrid recall, academic benchmarks, production fleet evidence | Concurrent writes (Postgres vs SQLite), RLS, provenance, EXPLAIN-able ranking | Not comparable — different category |

**Use GBrain if:** your use case is a personal knowledge graph from Markdown files and you want zero-config Postgres (PGLite). Not for multi-agent fleet memory.

**Use Memoir if:** you want taxonomy-organized memory with Git-like versioning and deterministic path-based retrieval. Alpha-stage; no standard recall benchmarks yet.

**Use agentmemory if:** you want drop-in memory for a single coding agent (Claude Code, Cursor) with zero-config auto-capture hooks. Accept SQLite single-writer limitation and per-observation LLM cost.

**Do not treat Odysseus as a memory competitor.** It is a self-hosted AI workspace (ChatGPT alternative). Memory is a bolted-on ChromaDB session feature, not a substrate.

---

## What would falsify our claims

| Claim | Falsification condition |
|---|---|
| **"Hybrid in-database recall"** | `pgmnemo.recall_lessons()` returns results computed via an external service call (vectors, BM25, or scoring executed outside Postgres) |
| **"Zero LLM cost per write"** | A standard `pgmnemo.ingest()` call triggers any embedding generation, fact extraction, or language model inference as part of the write path (under any gate mode: `enforce`, `warn`, or `off`) |
| **"No extra service required"** | pgmnemo requires a sidecar daemon, embedded runtime, or external API call to initialize or operate after `CREATE EXTENSION pgmnemo` and `SELECT pgmnemo.init_schema()` |
| **"Write-time provenance enforcement (gate_strict='enforce')"** | With `gate_strict='enforce'`, a standard `pgmnemo.ingest()` call succeeds (row reaches the heap) without either `commit_sha` or `artifact_hash` supplied, unless the caller has database SUPERUSER role |
| **"Bypass-proof enforcement from application layer"** | Application code executing under normal role (`SET ROLE agent_role`) writes a provenance-free row (no `commit_sha` / `artifact_hash`) with `gate_strict='enforce'` without triggering an RLS policy error or aborting the transaction |
| **"Configurable gate (enforce/warn/off modes)"** | The GUC `pgmnemo.gate_strict` fails to control `ingest()` behavior — e.g., `enforce` mode fails to reject unverified writes, or `off` mode blocks writes anyway |
| **"Works for conversational agents (mode 'off')"** | Conversational agent memory writes (no provenance artifact) fail or error with `gate_strict='off'` after `CREATE EXTENSION pgmnemo` and schema init |
| **"Works for backfill (mode 'warn')"** | Bulk INSERT of unverified memory rows succeeds with `gate_strict='warn'` but fails to emit warnings to the Postgres log, or emits errors instead of warnings |
| **Published recall@10 figures** | A reproducible re-run of the bench scripts on the published corpus snapshot (following `docs/BENCHMARK_PROTOCOL.md`) produces a value outside the published 95% confidence interval — triggering a public correction and card row update in this document |
| **Competitor facts** | Any published competitor attribute (license, LLM cost, architecture) contradicts official public documentation — correct immediately and publish a correction note in this file with date and evidence link |

---

## Benchmark honesty

pgmnemo publishes numbers with confidence intervals and mandatory negative cells. Full protocol: [docs/BENCHMARK_PROTOCOL.md](docs/BENCHMARK_PROTOCOL.md).

| Corpus | recall@10 | Honest note |
|---|---|---|
| LoCoMo (ACL 2024) | 0.8409 | Session-level; 22× smaller search space than paper Table 3 |
| LongMemEval-S (ICLR 2025) | 0.9604 | Gap to BM25 baseline (0.982) narrowed from −5pp (v0.5.x) to −2.2pp (v0.6.2 RRF Fix-A, p=0.017) |
| Production corpus (N=1,060, external adopter) | 0.5745 | Real-world agent memory; leave-one-out self-retrieval |

We publish where we lose. A benchmark that shows only wins is indistinguishable from cherry-picking.

---

*Apache 2.0 — [github.com/pgmnemo/pgmnemo](https://github.com/pgmnemo/pgmnemo)*
