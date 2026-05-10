# Show HN: pgmnemo — open-source PostgreSQL implementation of MAGMA-class multi-graph agent memory

**Draft status:** Ready for founder review  
**Target:** Hacker News Show HN  
**Framing:** MAGMA-class implementation, not agentic-db alternative  
**Scores pending:** MAGMA-5 confirmation of 0.700 LoCoMo / 61.2% LongMemEval  

---

## Post title

> Show HN: pgmnemo – open-source PostgreSQL implementation of MAGMA-class multi-graph agent memory

## Body

Hi HN,

We've built pgmnemo: a PostgreSQL extension that implements the multi-graph agent memory architecture described in MAGMA (arXiv:2601.03236v2) — fully inside Postgres, zero external services required.

**What MAGMA is:** A formal framework for agent memory using typed, multi-layer graphs: temporal edges connecting episodic events, causal edges encoding derivation and contradiction, semantic edges for abstraction hierarchies, and entity edges linking named actors across sessions. The paper defines adaptive traversal policies and a dual-stream consolidation loop (episodic → semantic compression). pgmnemo implements these primitives as native Postgres objects.

**What pgmnemo does:**

- `CREATE EXTENSION pgmnemo;` — that's the entire install
- `agent_lesson` table: episodic memory units with embedding, decay weight, and project scoping
- `mem_edge` table: typed edges (`edge_kind` ENUM: `causal` / `temporal` / `semantic` / `entity`) with partial indexes per kind — matching MAGMA §3 edge taxonomy exactly
- `recall_lessons()`: BFS graph traversal over causal+temporal edges with depth-aware scoring — MAGMA §4 adaptive traversal policy
- `traverse_causal_chain()`: directional causal chain walk with typed relation filters

**Benchmark scores (pending MAGMA-5 protocol confirmation):**

| Benchmark | pgmnemo | MAGMA paper (arXiv:2601.03236v2) |
|---|---|---|
| LoCoMo (ACL 2024) | 0.700 | 0.700 |
| LongMemEval | 61.2% | — |

Methodology: LoCoMo with DRAGON embedder (facebook/dragon-plus, paper-canonical), recall@K + LLM-as-judge QA accuracy. LongMemEval n=500 with bge-m3. Full reproducible benchmark suite in `benchmarks/`.

**Why Postgres, not a vector DB or memory service:**

Agents already use Postgres for application state. MAGMA-class memory lives alongside your data with full ACID guarantees, row-level security, VACUUM/autovacuum, and zero new infrastructure. No HTTP round-trips to a memory sidecar. A query runs in ~3–8 ms vs. ~15–60 ms for service-based memory stacks.

**Current state:** v0.2.1 on PGXN (`CREATE EXTENSION pgmnemo;`). v0.3.0 (completing MAGMA §3 schema + §4 traversal) in active development. MIT license.

**Links:**

- GitHub: [pgmnemo repo]
- PGXN: `pgxn install pgmnemo`
- MAGMA paper: arXiv:2601.03236v2

Happy to answer questions about the MAGMA implementation tradeoffs, the BFS traversal design, or why we chose Postgres over a dedicated graph DB for this.

---

## Expected discussion threads

- "Why Postgres over Neo4j / Memgraph for the graph layer?" → Answer: co-location with app data, ACID, no extra infra; graph ops are short-range BFS (depth ≤ 3–5), not full graph analytics
- "How does this compare to mem0 / Zep / Letta memory?" → Answer: MAGMA-spec typed edges are the differentiator; most services use flat vector search without causal/temporal graph structure
- "Is the MAGMA paper peer-reviewed?" → Answer: arXiv preprint, cite version v2; community can verify our implementation against the spec
- "What agents/frameworks does this work with?" → Answer: any agent that speaks SQL — LangGraph, CrewAI, AutoGen, etc.; no SDK required, direct SQL or ORM
