# Product Hunt Launch Draft

**Draft status:** Ready for founder review  
**Target:** Product Hunt  
**Framing:** MAGMA-class implementation, not agentic-db alternative  
**Scores pending:** MAGMA-5 confirmation of 0.700 LoCoMo / 61.2% LongMemEval  

---

## Tagline (≤60 chars)

> MAGMA-class multi-graph agent memory — inside PostgreSQL

## Thumbnail caption

> `CREATE EXTENSION pgmnemo;` — Typed causal, temporal & semantic memory graphs for AI agents. Zero services. Pure Postgres.

## Description (PH long form, ~300 words)

**pgmnemo** is an open-source PostgreSQL extension that implements the multi-graph agent memory architecture defined in the MAGMA paper (arXiv:2601.03236v2).

Most agent memory systems use flat vector search: embed a memory, store it, retrieve the top-K nearest vectors. MAGMA shows this misses the structure that makes memory useful: causal derivation chains, temporal ordering of episodes, semantic abstraction hierarchies, and entity co-occurrence graphs. pgmnemo implements all four as first-class typed edges in Postgres.

**How it works:**

1. Agent writes lessons via `INSERT INTO pgmnemo.agent_lesson` — episodic events with embeddings, decay weights, and project scope
2. Edges between lessons are stored in `pgmnemo.mem_edge` with an `edge_kind` ENUM: `causal` | `temporal` | `semantic` | `entity` (MAGMA §3 taxonomy)
3. `recall_lessons()` runs a BFS over causal+temporal edges with depth-weighted scoring (MAGMA §4 adaptive traversal policy)
4. `traverse_causal_chain()` walks directional causal chains — find what caused what, or what was derived from what

**Benchmark scores (pending MAGMA-5 protocol confirmation):**
- LoCoMo (ACL 2024): **0.700** — matches MAGMA paper reference
- LongMemEval: **61.2%** QA accuracy

**Why Postgres?** Agents already run on Postgres. MAGMA-class memory with ACID guarantees, row-level security, and pg_cron decay — no new infrastructure, no HTTP round-trips to a memory sidecar.

**One-line install:**
```
CREATE EXTENSION pgmnemo;
```

Available on PGXN. MIT license.

---

## First comment (maker comment)

Hey PH! Builder here.

The core insight from MAGMA (arXiv:2601.03236v2) is that agent memory isn't just a vector lookup — it's a multi-layer graph where causal chains, temporal sequences, and semantic abstractions each need different traversal strategies.

pgmnemo implements the MAGMA edge taxonomy directly in Postgres using typed ENUMs and partial indexes per edge kind. The BFS in `recall_lessons()` follows causal+temporal edges with depth scoring — this is the MAGMA §4 adaptive traversal policy running inside Postgres functions.

Our benchmark target: 0.700 on LoCoMo (matching the MAGMA paper's reference score) and 61.2% on LongMemEval — confirmation pending MAGMA-5 protocol run.

Would love questions on the graph traversal design, embedding strategy (bge-m3 / Stella V5), or how to integrate with your agent framework.

---

## Topics / tags

- Artificial Intelligence
- Developer Tools
- Open Source
- PostgreSQL
- AI Agents

## Gallery image captions

1. `pgmnemo schema — three tables, four edge kinds, pure Postgres`
2. `MAGMA §3 edge taxonomy: causal · temporal · semantic · entity`
3. `recall_lessons() BFS: depth-weighted graph traversal in SQL`
4. `Benchmark: 0.700 LoCoMo / 61.2% LongMemEval (MAGMA-5 pending)`
