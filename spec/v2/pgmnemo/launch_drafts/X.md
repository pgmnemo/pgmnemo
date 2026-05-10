# X (Twitter) Launch Threads

**Draft status:** Ready for founder review  
**Target:** X / Twitter  
**Framing:** MAGMA-class implementation, not agentic-db alternative  
**Scores pending:** MAGMA-5 confirmation of 0.700 LoCoMo / 61.2% LongMemEval  

---

## Thread 1 — Primary launch thread

**Tweet 1 (hook):**
> We built pgmnemo: open-source PostgreSQL implementation of MAGMA-class multi-graph agent memory.
>
> `CREATE EXTENSION pgmnemo;` — that's the entire install.
>
> MAGMA paper: arXiv:2601.03236v2
> Thread 🧵

**Tweet 2 (what MAGMA is):**
> MAGMA (arXiv:2601.03236v2) defines agent memory as a multi-layer typed graph:
>
> → causal edges: what caused what, derivations, contradictions  
> → temporal edges: episode ordering across sessions  
> → semantic edges: abstractions, elaborations, supersessions  
> → entity edges: named actor co-occurrence
>
> Most memory systems use flat vector search. This doesn't.

**Tweet 3 (what pgmnemo does):**
> pgmnemo implements the MAGMA §3 edge taxonomy in Postgres:
>
> `mem_edge.edge_kind` ENUM: causal | temporal | semantic | entity  
> Partial B-tree indexes per edge kind  
> `recall_lessons()` — BFS graph traversal with depth scoring (MAGMA §4)  
> `traverse_causal_chain()` — directional causal chain walk

**Tweet 4 (benchmarks):**
> Benchmark scores (MAGMA-5 protocol confirmation pending):
>
> LoCoMo (ACL 2024): **0.700**  
> LongMemEval: **61.2%** QA accuracy
>
> Reference: MAGMA paper (arXiv:2601.03236v2)  
> Embedder: facebook/dragon-plus (paper-canonical for LoCoMo)

**Tweet 5 (why Postgres):**
> Why Postgres instead of a graph DB or memory service?
>
> → Agents already run on Postgres  
> → ACID guarantees on memory writes  
> → Row-level security per agent/project  
> → No extra infra: `CREATE EXTENSION pgmnemo;` and go  
> → Query p50: ~3–8 ms

**Tweet 6 (install + CTA):**
> Available now on PGXN. MIT license.
>
> `pgxn install pgmnemo`  
> `CREATE EXTENSION pgmnemo;`
>
> GitHub: [link]  
> PGXN: [link]  
> MAGMA paper: arXiv:2601.03236v2
>
> Stars appreciated if you're building agents on Postgres ⭐

---

## Thread 2 — Technical deep-dive (for ML/systems audience)

**Tweet 1:**
> The graph traversal in pgmnemo's `recall_lessons()` is a BFS over MAGMA §4 adaptive traversal policy — implemented as a recursive SQL CTE inside Postgres.
>
> Here's how the depth scoring works 🧵

**Tweet 2:**
> MAGMA §4 says: when retrieving memories, proximity in the causal+temporal subgraph should boost relevance beyond pure embedding cosine similarity.
>
> pgmnemo implements this as a 5-component score:
>
> `(embedding_sim × 0.4) + (recency × 0.2) + (frequency × 0.2) + (importance × 0.1) + (graph_proximity × 0.1)`

**Tweet 3:**
> The `graph_proximity` component was *broken in v0.2.x* — the BFS was referencing a wrong column name so graph scoring was silently zero.
>
> v0.3.0 fixes it:
> ```sql
> WHERE me.edge_kind IN ('causal', 'temporal')
> ```
>
> This is the first time graph proximity actually fires in production.

**Tweet 4:**
> The `edge_kind` ENUM is the MAGMA §3 implementation detail that matters most for performance.
>
> Each kind gets its own partial B-tree index:
> - causal: `(source_id, target_id, weight DESC)`
> - temporal: `(source_id, created_at DESC, target_id)`
> - semantic: `(source_id, weight DESC, target_id)`
> - entity: `(source_id, target_id)`

**Tweet 5:**
> End result: a BFS traversal that uses the right index for each edge kind, with depth-weighted decay applied at the SQL level.
>
> No external graph DB. No memory service. Just Postgres.
>
> arXiv:2601.03236v2 is the spec. pgmnemo is the open implementation.

---

## Standalone tweets (for individual posting)

**Option A — concise pitch:**
> pgmnemo: open-source PostgreSQL implementation of MAGMA multi-graph agent memory (arXiv:2601.03236v2)
>
> Typed causal · temporal · semantic · entity edges in Postgres.  
> 0.700 LoCoMo / 61.2% LongMemEval (MAGMA-5 pending).  
> `CREATE EXTENSION pgmnemo;`

**Option B — benchmark focus:**
> MAGMA paper (arXiv:2601.03236v2) defines multi-graph agent memory with formal benchmarks.
>
> pgmnemo is the open-source PostgreSQL implementation.
>
> LoCoMo: 0.700 | LongMemEval: 61.2% (pending MAGMA-5 confirmation)  
> Install: `pgxn install pgmnemo`

**Option C — engineering angle:**
> We fixed a silent bug in pgmnemo v0.2.x: graph proximity scoring was effectively zero because `recall_lessons()` BFS used the wrong column name.
>
> v0.3.0 activates causal+temporal graph scoring for the first time.
>
> MAGMA §4 traversal, finally working.  
> arXiv:2601.03236v2
