# pgmnemo — POSITIONING v0.1

**Author:** growth_lead (92)
**Date:** 2026-04-29
**Status:** DRAFT — W1 deliverable
**Ref:** SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md, STRATEGY.md, MENTOR_REVIEW_2026-04-29.md

---

## 1. One-liner

> **pgmnemo is the provenance-gated memory layer for AI agents that already trust their PostgreSQL.**

---

## 2. Elevator pitch (HN / Twitter, 3 sentences)

Most AI agent frameworks ship their own memory — it's ephemeral, unauditable, and routes your data through someone else's cloud.
pgmnemo is a PostgreSQL extension: install with one SQL command, store and retrieve agent memory inside your existing database, and require a verifiable artifact before any lesson is promoted to long-term storage.
If your agents already run on Postgres, pgmnemo is the missing memory layer — zero new services, zero data egress, zero hallucinations promoted to fact.

---

## 3. Comparison table

| Dimension | **pgmnemo** | OpenBrain | Constructive AgenticDB | MAGMA | mem0 | Zep |
|---|---|---|---|---|---|---|
| **Install model** | `psql -f pgmnemo.sql` — pure SQL inside your existing DB | Separate service + MCP connector | `pgpm install agenticdb` — SQL DDL schema only, no compiled extension | Research system; no public install path | SaaS API (`pip install mem0ai` + API key) | SaaS API (`pip install zep-python` + API key) |
| **License** | Apache-2.0 | Proprietary (closed) | Apache-2.0 | Academic only (paper, no license) | MIT client / proprietary backend | Apache-2.0 client / proprietary backend |
| **Embedding stack** | bge-m3 multilingual — provider-agnostic; bring your own; no vendor required | OpenAI API required | User-supplied — no embedding layer bundled | Fixed research embeddings (not configurable) | OpenAI + Cohere adapters (vendor-coupled) | OpenAI embeddings (vendor-coupled) |
| **Distillation** | FastAPI curator: cosine-dedup (sim > 0.92), LLM consolidation, pg_cron scheduling | None documented | None | Academic summarisation only | None | Entity extraction only (no consolidation) |
| **Provenance gate** | **Yes** — lesson write blocked without commit SHA or artifact hash | No | No | No | No | No |
| **Multi-agent role isolation** | Yes — PostgreSQL RLS per agent role + project composite | API-level only (no DB enforcement) | No | No | No | No |
| **Scale ceiling** | PostgreSQL row count — pgvector handles 100M+ rows; self-hosted unlimited | Service-defined; vendor-managed | PostgreSQL row count; no vector index layer | Lab-scale only (not production-hardened) | Vendor-managed (SaaS limits apply) | Vendor-managed (SaaS limits apply) |
| **Price** | Free — Apache-2.0 OSS | Unknown (closed beta) | Free OSS — managed cloud pending funding | Free (research artefact, not a product) | $0.004 / 1K reads on proprietary backend | $0.0001 / message + cloud infra costs |

---

## 4. Wedge customer profile — the first 10 developers

These are the specific people who would clone the repo on day 1 and file the first 5 GitHub issues.

**Stack:** Python or TypeScript, calling Claude / OpenAI / Ollama. Already on PostgreSQL — Supabase (most common), Neon, or self-hosted PG17 on a $20/mo VPS. They run pgvector today. They have never installed a compiled Rust extension and do not want to.

**Team size:** 1–3 people. Side project or early startup. No dedicated DevOps.

**Current pain:** They built a multi-agent pipeline (research → write → review, or plan → code → test). Each run starts from zero context. They store "memory" in a JSON file or a Redis key that expires. When an agent hallucinates and writes a bad summary, that summary gets stored as memory for the next run. They've watched cascading failures — agent 2 trusted agent 1's wrong output, and it compounded across 10 runs. They're about to write their own dedup logic. They want it in Postgres because that's where everything else already lives.

**Why pgmnemo on day 1:** They see "PostgreSQL extension, zero new services, provenance gate" in the README and recognise it as the abstraction they were about to build themselves. They install it in under 5 minutes and replace 200 lines of ad-hoc memory code with two SQL function calls.

**The 10 specific developers:**

1. Solo founder building a code-review agent pipeline on Claude; stores review comments as agent memory; frustrated by hallucinated memories poisoning later runs after a bad LLM call.
2. Two-person startup building a research-to-blog agent on Neon; already uses pgvector for semantic search on source articles; memory is the obvious next layer.
3. Freelance developer on r/LocalLLaMA running Ollama locally; vendor-API-free matters; wants offline-capable memory that doesn't call home.
4. Backend developer at a 10-person fintech who cannot send customer data to external APIs (compliance team said no); runs PostgreSQL on-prem and needs memory that physically stays there.
5. PhD student studying multi-agent systems who found pgvector via a paper; needs reproducible memory experiments with provenance tracking for the methods section.
6. DevOps engineer at a consultancy who builds AI assistants for clients; hates adding new services to the client's infra stack; one SQL file is architecturally honest.
7. Developer at an EU or Russian company under data sovereignty rules; memo: data cannot leave the server; Supabase EU is the ceiling they can use today.
8. Open-source contributor who maintains a Postgres-based project management tool and wants to add AI-agent memory without changing the deployment model for 10,000 self-hosted users.
9. Indie hacker who saw the Constructive AgenticDB HN announcement, searched the comments for alternatives, and found pgmnemo mentioned as "provenance-gated."
10. ML engineer at an early startup who tried mem0 free tier, got the $200/month bill projection at their scale, and is actively searching for a self-hosted alternative right now.

---

## 5. Differentiator narrative — the provenance gate (no academic jargon)

When an AI agent does work — researches a topic, writes code, reviews a document — it should leave a lesson behind: "here's what I learned, here's what worked." That lesson should improve the next agent that picks up the same task.

The problem is that AI agents get things wrong. They write confident, incorrect summaries and store them as fact. Every memory system on the market stores whatever the agent says, without questioning it. Three weeks later, a different agent reads the hallucinated lesson and builds on it. The mistake compounds. You end up with a memory layer that accumulates noise at the same rate it accumulates knowledge — and there's no way to tell which is which.

pgmnemo blocks that pattern with a provenance gate. Before any lesson is promoted to long-term memory, it must be attached to a verifiable artifact: a git commit SHA, a file hash, a passing test result ID. If no artifact exists, the lesson stays in a staging queue — useful for the current session, not trusted for future ones. The gate runs inside PostgreSQL as a row-level security policy, enforced at the database layer. It cannot be bypassed by application code, and it leaves a permanent audit trail you can query at any time.

The practical effect: if an agent claims it completed a task and there is no commit to prove it, the "lesson" from that run does not enter long-term memory. Phantom work stays phantom. Real work gets remembered.

No other agent memory system does this. It is the difference between a memory layer that grows smarter and one that grows noisier.

---

## 6. Three things we will NOT claim (anti-promises)

1. **We will not claim pgmnemo replaces your vector database.** It uses pgvector for approximate nearest-neighbour search, which is good enough for most agent workloads up to several hundred thousand rows. If you are running billion-row retrieval at sub-10ms latency, you need a dedicated vector database. pgmnemo does not compete there, and we will not pretend it does.

2. **We will not claim provenance makes your agents safe.** The gate verifies that a commit or artifact existed at write time — it does not verify that the artifact is correct. A bad commit still passes. A hallucinated file hash from a broken tool call does not. Provenance is an accountability and dedup mechanism, not a correctness guarantee or a safety certification.

3. **We will not claim the compiled-extension moat is ready.** Today pgmnemo ships as PL/pgSQL functions — SQL scripts, not a compiled binary. Custom index types, temporal decay scoring, and access-method-level operators are on the roadmap, not in the current release. Any benchmark or claim invoking "compiled Postgres extension performance" does not yet apply to pgmnemo v0.x. We will say so clearly when it does.
