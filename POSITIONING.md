# pgmnemo Positioning
**REVISED — Stage 2 Gate-Modes Reframe (WG-RESTRATEGY-260519-v3)**

**Postgres extension for agent memory: hybrid recall, zero-cost writes, optional provenance enforcement.**

*One `CREATE EXTENSION` command. Hybrid vector + BM25 recall. Zero LLM inference per write. Provenance gate configurable via GUC: `enforce` / `warn` / `off`.*

> In-database agent memory substrate. Self-hosted. No new service. No vendor lock-in.

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

**The differentiator claim:** pgmnemo is the only Postgres extension that combines hybrid in-database recall (vectors + BM25) with optional write-time compliance enforcement via database constraints — making it simultaneously the simplest agent memory layer for conversational agents AND the only provenance-gated option for citation-grounded agents.

---

## Competitor matrix

| Dimension | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive AgenticDB |
|---|---|---|---|---|---|
| **Recall architecture** | ✅ In-database — HNSW + BM25 hybrid in SQL; no service hop | ❌ Cloud-hosted API; latency + data egress | ⚠️ Self-hosted option; default Zep Cloud | ⚠️ Self-hosted Python + external graph DB | ✅ In-database — HNSW in SQL via pgvector |
| **Install model / vendor lock-in** | ✅ `CREATE EXTENSION pgmnemo` in your Postgres; fully portable | ❌ SaaS API (Mem0 Cloud); vendor locked; no self-hosted option | ⚠️ Self-hosted is possible (Graphiti OSS); Zep default is SaaS | ⚠️ Self-hosted Python service (Letta Cloud available) | ✅ `CREATE EXTENSION constructive_agenticdb` in your Postgres |
| **LLM cost per write** | ✅ **Zero** — SQL constraint check only; no model inference at ingest | ❌ ~$0.17 per 1,000 writes (GPT-4o-mini fact extraction) | ❌ ~$0.36 per 1,000 writes (gpt-4o-mini, post-v0.29.0) | ✅ Zero extra (write is part of agent turn already invoiced) | ✅ Zero (local Ollama embeddings only) |
| **Data residency / self-hosted** | ✅ Your Postgres, your infrastructure. HIPAA-compatible by architecture (data never leaves your VPC) | ❌ Mem0 Cloud (proprietary hosted); data on Mem0 infrastructure | ⚠️ Zep Cloud default; self-hosted option (Graphiti) moves data control locally | ⚠️ Self-hosted (Letta) or Letta Cloud SaaS; you choose | ✅ Your Postgres, your infrastructure; no SaaS |
| **Optional compliance enforcement** | ✅ Write-time provenance gate — `enforce` / `warn` / `off` modes; RLS-enforced at Postgres constraint layer | ❌ No gate; `metadata` is post-hoc logging only | ❌ Episode references are descriptive, not a write-time veto | ❌ `core_memory_append` is unconditional; no write-time check | ❌ No provenance gate |
| **Target ICP breadth** | ✅ Three segments: citation-grounded (enforce), conversational (off), backfill (warn) — single product, configurable | ✅ General agent memory incl. conversational agents | ✅ Knowledge-graph agent memory (different optimization) | ✅ Long-context conversational agents | ⚠️ Generic agent memory; no compliance specialization |
| **Temporal memory** | ✅ `created_at` + bitemporal (`t_valid_from`/`t_valid_to`); `mem.as_of()` targeting v0.5.0; causal edges | ✅ Yes (managed, cloud) | ✅ Bitemporal edges at graph layer; LLM-detected contradiction resolution | ⚠️ Block-level via `core_memory_append` | ⚠️ Not publicly documented |
| **License / hosting model** | ✅ Apache 2.0 — fully self-hosted; no managed tier | ❌ Proprietary SaaS; open-source SDK only | ✅ Apache 2.0 (Graphiti OSS) + optional Zep Cloud SaaS | ✅ MIT + optional Letta Cloud SaaS | ✅ MIT — fully self-hosted |
| **Production scale evidence** | ⚠️ 1 production deployment (early adopter, external team) | ✅ 186M+ API calls/month; 80K+ registered developers (2025) | ✅ Zep: enterprise tier customers; Graphiti: growing OSS | ✅ 1M+ agents in production (Bilt, Aurora Postgres backend) | ⚠️ Not publicly documented |

**Constructive AgenticDB note:** license is MIT (not Apache-2.0); vector index is HNSW via pgvector (cosine/L2/inner-product); embeddings are bundled (Ollama + nomic-embed-text, local inference, no hosted API required). Constructive is the closest architectural peer to pgmnemo — same Postgres-extension install model, no managed service. The differentiator vs Constructive is write-time provenance enforcement at the RLS layer; Constructive does not enforce.

---

## What would falsify our claims

| Claim | Falsification condition |
|---|---|
| "Provenance-enforced for citation-grounded agents" | A standard `pgmnemo.ingest()` call with no `commit_sha` / `artifact_hash` succeeds at the Postgres layer (row reaches the heap) without SUPERUSER-level bypass |
| "No extra service required" | pgmnemo requires a sidecar process, external API call, or embedded runtime service to initialize or operate after `CREATE EXTENSION` |
| "Zero LLM cost per write" | A standard `pgmnemo.ingest()` call triggers any model inference — embedding generation or fact extraction — as part of the write path |
| "Bypass-proof enforcement from application layer" | Application code executing under a normal role (`SET ROLE agent_role`) writes a provenance-free row without triggering an RLS policy error |
| "Hybrid recall in-database" | `pgmnemo.recall_lessons()` issues any network call to an external service as part of retrieval |
| Published recall@10 figures | A reproducible re-run of the bench scripts on the published corpus snapshot (following `docs/BENCHMARK_PROTOCOL.md`) produces a value outside the published 95% confidence interval — triggering a public correction and card row update |
| Constructive AgenticDB facts (MIT / HNSW / bundled Ollama) | Constructive's public license file or official documentation contradicts any of the three corrected values — correct immediately and publish a correction note |

---

## Benchmark honesty

pgmnemo publishes numbers with confidence intervals and mandatory negative cells. Full protocol: [docs/BENCHMARK_PROTOCOL.md](docs/BENCHMARK_PROTOCOL.md).

| Corpus | recall@10 | Honest note |
|---|---|---|
| LoCoMo (ACL 2024) | 0.8409 | Session-level; 22× smaller search space than paper Table 3 |
| LongMemEval-S (ICLR 2025) | 0.9334 | **Loses to BM25 baseline (0.982) by ~5pp** — gap targeted for v0.5.0 |
| Production corpus (N=1,060, external adopter) | 0.5745 | Real-world agent memory; leave-one-out self-retrieval |

We publish where we lose. A benchmark that shows only wins is indistinguishable from cherry-picking.

---

*Apache 2.0 — [github.com/pgmnemo/pgmnemo](https://github.com/pgmnemo/pgmnemo)*
