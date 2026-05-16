# pgmnemo Positioning

**The write-time gate for agent memory.**

*Every `ingest()` call is verified against source provenance before the row commits.*

> One Postgres extension. Write-time provenance. No extra service.

---

## Why pgmnemo exists

MemGPT showed that agents need persistent memory. pgmnemo shows that memory needs a gate.

Agent memory systems fail in a specific way: a hallucinated fact, a stale belief, a poisoned retrieval — none are blocked at write time. They enter memory silently, accumulate, and surface as retrieval results. Post-hoc audit logs record what went wrong; they do not prevent it.

pgmnemo enforces provenance at the database constraint and row-security level, inside the Postgres transaction, before any row reaches the heap. An `ingest()` call without a valid `commit_sha` or `artifact_hash` is rejected by the Postgres executor — not by application code, not by middleware, not after the fact. A compromised or buggy agent cannot write a provenance-free memory row without database superuser access, regardless of how the `INSERT` is constructed.

**The claim:** pgmnemo is the only agent memory layer whose provenance enforcement is architecturally impossible to bypass from the application layer.

---

## Competitor matrix

| Dimension | **pgmnemo** | Mem0 | Zep / Graphiti | Letta | Constructive AgenticDB |
|---|---|---|---|---|---|
| **Write-time provenance gate** | ✅ RLS-enforced — `INSERT` rejected at DB constraint level without valid provenance | ❌ No gate; `metadata=` is a post-hoc log, not a write veto | ❌ Episode back-references are descriptive provenance, not a write-time veto | ❌ `core_memory_append` is unconditional; no quality gate, no provenance check | ❌ No provenance gate |
| **Install model** | `CREATE EXTENSION pgmnemo` in your existing Postgres instance | SaaS API (cloud-hosted) | Self-hosted Python service + graph database | Self-hosted Python service (Letta Cloud available) | `pgpm install constructive_agenticdb` (Postgres extension) |
| **LLM calls per write** | **0** — SQL gate only, no model inference at ingest | ~1 (GPT-5-mini fact extraction; ~$0.17 per 1,000 writes) | ~1 post-v0.29.0; was ~3 (~$0.36 per 1,000 writes at gpt-4o-mini) | 0 extra (write is part of the agent turn already paid) | 0 (embedding trigger only; local Ollama, ~$0 compute) |
| **Temporal memory** | `created_at` (v0.4.x); `t_valid_from`/`t_valid_to` + `mem.as_of()` targeting v0.5.0 | Yes (managed, cloud) | Yes — bitemporal edges at the graph layer; LLM-detected contradiction resolution | Limited — block-level via `core_memory_append` | Not publicly documented |
| **License / hosting** | Apache 2.0 — self-hosted; no SaaS | Proprietary SaaS; open-source client SDK | Apache 2.0 (Graphiti OSS) + Zep Cloud (managed SaaS) | MIT + Letta Cloud (managed SaaS) | **MIT** — self-hosted Postgres extension |
| **Production scale evidence** | 1 production deployment (early adopter, external team) | 186M+ API calls/month; 80K+ registered developers (2025) | Zep: enterprise tier customers; Graphiti: growing OSS community | 1M+ personalized agents in production (Bilt, Aurora Postgres backend) | Not publicly documented |

**Constructive AgenticDB note:** license is MIT (not Apache-2.0); vector index is HNSW via pgvector (cosine/L2/inner-product); embeddings are bundled (Ollama + nomic-embed-text, local inference, no hosted API required). Constructive is the closest architectural peer to pgmnemo.

---

## What would falsify our claims

| Claim | Falsification condition |
|---|---|
| "Write-time provenance gate" | A standard `pgmnemo.ingest()` call with no `commit_sha` / `artifact_hash` succeeds at the Postgres layer (row reaches the heap) without SUPERUSER-level bypass |
| "No extra service required" | pgmnemo requires a sidecar process, external API call, or embedded runtime service to initialize or operate after `CREATE EXTENSION` |
| "Zero LLM cost per write" | A standard `pgmnemo.ingest()` call triggers any model inference — embedding generation or fact extraction — as part of the write path |
| "Bypass-proof enforcement" | Application code executing under a normal role (`SET ROLE agent_role`) writes a provenance-free row without triggering an RLS policy error |
| "Hybrid recall in-database" | `pgmnemo.recall_lessons()` issues any network call to an external service as part of retrieval |

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
