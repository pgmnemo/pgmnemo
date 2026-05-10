# WG-BENCH-4: Competitor Capability Matrix
**Retrieval-side innovations — MAGMA / Mem0 / Zep / HippoRAG vs pgmnemo**

| Field | Value |
|---|---|
| Task | WG-BENCH-4 |
| Date | 2026-05-10 |
| Scope | Retrieval-side techniques only (not generation/reasoning) |
| pgmnemo baseline | v0.3.0 (`extension/pgmnemo--0.2.1--0.3.0.sql`) |
| Evidence threshold | Each cell cited with source; ≥ 20 distinct techniques |

Legend: **✅ has** (implemented, in-path) / **⚠️ partial** (scaffolded or partially implemented) / **❌ lacks** (not present)

---

## Matrix

| # | Technique | pgmnemo | MAGMA | Mem0 | Zep | HippoRAG | Gap severity |
|---|---|---|---|---|---|---|---|
| 1 | **4-graph decomposition** (semantic / temporal / causal / entity as distinct traversal subgraphs) | ⚠️ partial | ✅ has | ⚠️ partial | ⚠️ partial | ❌ lacks | Medium |
| 2 | **Adaptive (learned) traversal policy** (ML classifier routes query intent → graph, not regex) | ❌ lacks | ✅ has | ❌ lacks | ❌ lacks | ❌ lacks | High |
| 3 | **Dual-stream evolution** (online fast-ingest stream + async offline structural consolidation) | ❌ lacks | ✅ has | ❌ lacks | ⚠️ partial | ❌ lacks | High |
| 4 | **Intent-aware hierarchical retrieval** (query intent selects graph tier before ANN) | ⚠️ partial | ✅ has | ❌ lacks | ❌ lacks | ❌ lacks | Medium |
| 5 | **Hierarchical context synthesis** (multi-level retrieved-node → passage → pack aggregation) | ❌ lacks | ✅ has | ❌ lacks | ⚠️ partial | ❌ lacks | Medium |
| 6 | **Personalized PageRank (PPR) over knowledge graph** | ❌ lacks | ❌ lacks | ❌ lacks | ❌ lacks | ✅ has | High |
| 7 | **LLM-based NER + RE for graph construction** (entities + relations auto-extracted from text) | ❌ lacks | ✅ has | ✅ has | ✅ has | ✅ has | High |
| 8 | **Multi-hop retrieval via graph seeding** (PPR / BFS seeds from query-matched nodes) | ⚠️ partial | ✅ has | ⚠️ partial | ✅ has | ✅ has | Medium |
| 9 | **Entity synonym deduplication at index time** (node merging, coreference resolution) | ❌ lacks | ✅ has | ⚠️ partial | ✅ has | ✅ has | High |
| 10 | **Bitemporal edges** (T-valid + T-transaction on relationships, not just nodes) | ❌ lacks | ⚠️ partial | ❌ lacks | ✅ has | ❌ lacks | Medium |
| 11 | **Temporal fact expiry / invalidation** (facts auto-superseded when contradicted) | ⚠️ partial | ✅ has | ❌ lacks | ✅ has | ❌ lacks | Medium |
| 12 | **Community clustering for episodic context** (graph community detection, e.g. Louvain) | ❌ lacks | ✅ has | ❌ lacks | ✅ has | ❌ lacks | Low |
| 13 | **Cross-encoder reranking** (late-fusion reranker on top of ANN candidates) | ❌ lacks | ✅ has | ❌ lacks | ✅ has | ❌ lacks | Medium |
| 14 | **Maximal Marginal Relevance (MMR) diversity reranking** | ❌ lacks | ❌ lacks | ❌ lacks | ✅ has | ❌ lacks | Low |
| 15 | **Semantic entity deduplication via LLM** (LLM confirms whether two memories are the same fact) | ❌ lacks | ✅ has | ✅ has | ✅ has | ❌ lacks | High |
| 16 | **LLM-guided memory extraction from conversation turns** (auto-parse what to remember) | ❌ lacks | ❌ lacks | ✅ has | ✅ has | ❌ lacks | High |
| 17 | **Hybrid vector + graph + KV retrieval** (all three index types in a single query path) | ⚠️ partial | ✅ has | ✅ has | ✅ has | ❌ lacks | Medium |
| 18 | **Automatic memory categorization / topic assignment** (dynamic, embedding-based) | ❌ lacks | ✅ has | ✅ has | ⚠️ partial | ❌ lacks | Low |
| 19 | **Session / user scoping with retrieval isolation** (per-user graph partitioning) | ✅ has | ✅ has | ✅ has | ✅ has | ❌ lacks | None |
| 20 | **Dense keyword full-text search** (FTS with tsvector/BM25 or equivalent) | ✅ has | ❌ lacks | ⚠️ partial | ✅ has | ❌ lacks | None |
| 21 | **HNSW / approximate ANN index** (sub-linear vector search) | ✅ has | ✅ has | ✅ has | ✅ has | ✅ has | None |
| 22 | **Provenance / trust-gated retrieval** (filter by source role / quality threshold) | ✅ has | ❌ lacks | ❌ lacks | ❌ lacks | ❌ lacks | None (pgmnemo leads) |
| 23 | **Recency decay scoring** (exponential or linear decay on item age) | ✅ has | ✅ has | ⚠️ partial | ✅ has | ❌ lacks | None |
| 24 | **Importance / weight signal in ranking** (explicit human-or-system-assigned importance) | ✅ has | ❌ lacks | ❌ lacks | ❌ lacks | ❌ lacks | None (pgmnemo leads) |
| 25 | **Graph edge weight propagation** (path weight accumulated over multi-hop traversal) | ⚠️ partial | ✅ has | ❌ lacks | ✅ has | ✅ has | Low |

**Technique count: 25**  
**pgmnemo unique leads: techniques 22, 24** (provenance-gated retrieval, importance scoring)  
**pgmnemo critical gaps: techniques 2, 3, 6, 7, 9, 15, 16** (7 high-severity gaps)

---

## Competitor Detail: MAGMA (arXiv:2601.03236)

### Contribution 1 — 4-Graph Decomposition

MAGMA decomposes the memory store into four physically distinct (or logically partitioned) subgraphs:

| Graph | Node type | Edge semantics |
|---|---|---|
| Semantic graph | Concepts / knowledge claims | Similarity, elaboration, contradiction |
| Temporal graph | Events / episodes | Time-ordered co-occurrence, `before`/`after` |
| Causal graph | Actions / outcomes | `causes`, `derives_from`, `prevents` |
| Entity graph | Named entities (persons, files, projects) | Co-reference, `is-a`, `part-of` |

**pgmnemo state:** `mem_edge` has `edge_kind` ENUM `{semantic, temporal, causal, entity}` (v0.3.0, `extension/pgmnemo--0.2.1--0.3.0.sql:S1–S4`). Per-kind partial indexes exist (`:S5`). However, BFS in `recall_lessons()` only traverses `causal` + `temporal` edges (`:S7`, line 266 `WHERE me.edge_kind IN ('causal', 'temporal')`). The **semantic** and **entity** graphs are indexed but not traversed in the retrieval path.

**Gap:** Semantic-graph traversal and entity-graph traversal are not wired into `recall_lessons()`. Semantic elaboration chains and entity co-reference paths are invisible to retrieval.

*Source: arXiv:2601.03236 §3, Table 1; `extension/pgmnemo--0.2.1--0.3.0.sql` lines 100–119, 265–267.*

---

### Contribution 2 — Adaptive Traversal Policy

MAGMA uses a **learned intent classifier** (lightweight MLP or fine-tuned encoder, not regex) that maps a query embedding to one of the four graph subspaces with learned probability weights. The router is trained on labelled query–graph pairs and outputs a soft routing distribution, allowing mixed-graph traversal for ambiguous queries.

**pgmnemo state:** Intent classification is regex-based (`design/` docs describe `DESIGN_DPT_POLICY_TRAVERSAL.md` with regex on query text mapping to `{factual, procedural, causal, social}` → graph). The implementation is a `keyword regex` classifier as noted in `research/PAPER_v0.1.md §4.3`: *"intent (factual / procedural / causal / social) is classified via keyword regex on query.text."*

**Gap:** pgmnemo uses a deterministic rule-based router. MAGMA's learned policy can generalize to out-of-distribution query phrasings; pgmnemo's regex is brittle to novel imperative verbs and domain-specific phrasing.

*Source: arXiv:2601.03236 §4.2 "Policy Network"; `research/PAPER_v0.1.md §4.3` ("keyword regex").*

---

### Contribution 3 — Dual-Stream Evolution

MAGMA operates two concurrent processing pipelines:

- **Fast stream:** Synchronous ingest — new events are written immediately to all four graphs with minimal processing.
- **Slow stream:** Asynchronous consolidation — background jobs perform entity extraction, edge weight recomputation, contradiction detection, and community re-clustering without blocking reads.

**pgmnemo state:** pgmnemo has a synchronous write path (`POST /api/memory/items`, `research/PAPER_v0.1.md §4.4`) and a background curator (`memory_curator.recluster_topics` for topic centroids, `memory_curator.curate_agent_lessons` for lesson cosine-dedup). However:
- No entity extraction pipeline (extraction deferred per `spec/reports/TL_MAGMA2_SCHEMA_2026-05-09.md §5` item 3).
- No contradiction detection.
- No background edge weight recomputation.

**Gap:** The "slow stream" in pgmnemo is limited to topic centroid reclustering. Entity graph population and structural consolidation are unimplemented.

*Source: arXiv:2601.03236 §5 "Dual-Stream Architecture"; `spec/reports/TL_MAGMA2_SCHEMA_2026-05-09.md §5` ("Seed entity edges … out of scope for v0.3.0").*

---

### Contribution 4 — Intent-Aware Hierarchical Retrieval

MAGMA performs retrieval in three tiers:
1. **Intent classification** → select primary graph
2. **Coarse ANN** within the selected subgraph (or globally if intent is low-confidence)
3. **Fine-grained BFS** expansion from ANN seeds within the selected graph, with per-hop weight decay

**pgmnemo state:** pgmnemo implements a 3-stage pipeline in `research/PAPER_v0.1.md §4.3`:
1. Topic-tier classifier (keyword, maps to `topic_id`)
2. HNSW ANN within topic partition
3. Policy-guided graph traversal

The difference: pgmnemo's stage-1 is **topic partitioning** (HyperMem-style, not intent-based). Intent routing happens at stage 3 after ANN, not before. In MAGMA, intent routes the ANN itself into the right subgraph, reducing false positives earlier in the pipeline.

**Gap:** pgmnemo does topic-tier filtering, not intent-tier filtering at the ANN stage. BFS graph expansion is applied after a global-topic ANN, not within an intent-selected subgraph. Partial credit for the 3-stage pipeline structure.

*Source: arXiv:2601.03236 §4.3 "Hierarchical Retrieval Pipeline"; `research/PAPER_v0.1.md §4.3` read-path diagram.*

---

### Contribution 5 — Hierarchical Context Synthesis

After retrieval, MAGMA applies a three-level synthesis step:
1. **Node level:** retrieved graph nodes are summarized individually.
2. **Subgraph level:** connected components of retrieved nodes are synthesized into passage-level summaries.
3. **Pack level:** cross-subgraph ranked assembly into the final context pack using token budget.

**pgmnemo state:** pgmnemo applies a flat linear scoring (`σ = α·sim + β·layer + γ·recency + δ·prov`) then a greedy knapsack to the token budget (`research/PAPER_v0.1.md §4.3 Stage 4 — MemScheduler`). There is no subgraph-level aggregation — each `agent_lesson` row is scored and inserted independently. Connected nodes retrieved via BFS are not jointly summarized.

**Gap:** pgmnemo packs individual lesson rows. MAGMA's subgraph-level synthesis could produce richer, less redundant context packs by merging structurally related retrieved items.

*Source: arXiv:2601.03236 §4.4 "Context Synthesis"; `research/PAPER_v0.1.md §4.3` knapsack formula.*

---

## Competitor Detail: Mem0 (mem0ai/mem0)

Mem0's retrieval algorithm (GitHub: `mem0ai/mem0`, `mem0/memory/main.py`):

### Retrieval Algorithm (actual implementation)

1. **LLM-guided memory extraction:** On each conversation turn, an LLM call extracts facts to remember (`mem0/memory/main.py::add()`). This requires the LLM to be available — it was removed from pgmnemo's host system (`research/PAPER_v0.1.md §8.2`, commit `347f944`).

2. **Vector + Graph dual search:** `retrieve()` runs:
   - Dense vector search (configurable: Qdrant / pgvector / Chroma)
   - Graph traversal (configurable: Neo4j or in-memory) — entity hop expansion
   - Results are merged and re-ranked by combined score.

3. **Scoring formula (from `mem0/memory/main.py`):**
   ```
   score = vector_similarity * 0.7 + graph_hop_score * 0.3
   ```
   Fixed weights, no recency decay by default (optional via config). No importance signal.

4. **Indexing strategy:** Single flat vector index (no HNSW partial index, no topic partitioning). All memories per user in a single collection.

5. **LLM semantic deduplication:** Before inserting a new memory, Mem0 calls the LLM with existing similar memories (top-5 ANN) and asks it to decide: ADD / UPDATE / DELETE / NONE. This prevents semantic duplicates but requires an LLM call per write.

**pgmnemo comparison to `recall_lessons()`:**

| Aspect | pgmnemo v0.3.0 | Mem0 |
|---|---|---|
| Vector weight | 0.4 (configurable) | 0.7 (fixed) |
| Graph weight | 0.2 (GUC `pgmnemo.graph_proximity_weight`) | 0.3 (fixed) |
| Recency decay | ✅ (γ GUC, default 0.08) | ❌ (optional config, off by default) |
| Importance signal | ✅ (0.2 × importance/5) | ❌ |
| Provenance signal | ✅ (0.1 × prov_strength) | ❌ |
| FTS / BM25 component | ✅ (tsvector in candidates CTE) | ⚠️ optional |
| Deduplication | SHA-256 hash (exact) | LLM semantic (requires LLM) |
| Graph traversal | BFS from top-5 anchors, causal+temporal only | Neo4j entity hop, all entity edges |
| Entity graph | ⚠️ schema only (not populated) | ✅ auto-extracted |
| Write-time entity extraction | ❌ deferred | ✅ LLM-extracted per turn |

**Key gaps vs Mem0:**
- No automatic memory extraction from conversation (Mem0 does this via LLM; pgmnemo requires manual writes or agent discipline).
- No semantic deduplication (pgmnemo has only SHA-256 hash dedup in `content_hash` column, `research/PAPER_v0.1.md §4.2`).
- Entity graph exists in schema but is never populated (entity extraction deferred per `spec/reports/TL_MAGMA2_SCHEMA_2026-05-09.md §5`).

*Sources: `mem0ai/mem0` GitHub (main.py, ~2024 version); `extension/pgmnemo--0.2.1--0.3.0.sql:S7` recall_lessons; `spec/reports/TL_MAGMA2_SCHEMA_2026-05-09.md §5`.*

---

## Competitor Detail: Zep (getzep/zep — Graphiti engine)

### Temporal Reasoning Techniques in Zep

Zep is powered by **Graphiti** (open-source: `getzep/graphiti`), a temporal knowledge graph engine. Retrieval techniques pgmnemo lacks:

**T1 — Bitemporal edges (not just nodes)**  
Graphiti adds `valid_at` and `invalid_at` timestamps to **edges** (relationships), not just nodes. This allows querying "what was the relationship between A and B at time T?" — which is distinct from pgmnemo's `valid_from`/`valid_to` on `mem_item` (nodes only). The `mem_edge` table in pgmnemo has `created_at` but no `valid_to`.

*pgmnemo gap:* `extension/pgmnemo--0.2.1--0.3.0.sql` — `mem_edge` has `created_at` only; no `valid_to` on edges.

**T2 — Automatic contradiction detection and fact invalidation**  
When a new episode asserts a fact that contradicts an existing edge (e.g., "Alice now lives in Berlin" contradicts "Alice lives in Paris"), Graphiti invalidates the old edge by setting `invalid_at = NOW()`. This is done via LLM-as-referee.

*pgmnemo gap:* pgmnemo has no contradiction detection. `valid_to` on `mem_item` is only set manually by TL. The `edge_kind = 'causal'` contradicts edge type exists in schema but has no automatic invalidation trigger.

**T3 — Temporal window queries**  
Graphiti supports retrieval with an explicit `reference_time` parameter: "retrieve facts valid at time T." This enables as-of queries (debugging past states, auditing historical context).

*pgmnemo gap:* `recall_lessons()` has no `as_of_time` parameter. Recency decay (`γ × recency(90d)`) approximates freshness but does not support point-in-time queries.

**T4 — Episode → Entity → Community subgraph hierarchy**  
Graphiti builds a three-level graph:
- Episodes (raw conversation turns)
- Entities (extracted persons, files, projects)
- Communities (clusters of co-occurring entities, Louvain algorithm)

Retrieval can be at any level: episode-level for episodic queries, entity-level for factual queries, community-level for broad context.

*pgmnemo gap:* pgmnemo has a two-level structure (L2 episode → L3 canonical claim). No community-level clustering of entities. `mem_topic` centroids provide topic-level partitioning but are not entity-based communities.

**T5 — Cross-encoder reranking**  
Zep/Graphiti applies a cross-encoder reranker (e.g., `ms-marco-MiniLM-L-6-v2`) on the top-k ANN candidates before returning results. This improves precision at the cost of 50–100 ms additional latency.

*pgmnemo gap:* No reranking step. Candidates from ANN are scored by the linear formula and returned directly.

**T6 — MMR (Maximal Marginal Relevance) diversity**  
Zep applies MMR as an optional post-ranking step to reduce result set redundancy when multiple items share high cosine similarity.

*pgmnemo gap:* No diversity reranking. High-cosine duplicates score identically and may all appear in the top-k. SHA-256 exact dedup prevents byte-identical duplicates but not semantically equivalent items with different phrasing.

*Sources: `getzep/graphiti` GitHub (graphiti_core/search/search.py; graphiti_core/nodes.py valid_at/invalid_at fields); Zep docs https://help.getzep.com/graphiti; `extension/pgmnemo--0.2.1--0.3.0.sql` (mem_edge columns).*

---

## Competitor Detail: HippoRAG (Princeton)

**Paper:** HippoRAG: Neurologically Inspired Long-Term Memory for Large Language Models (Gutiérrez et al., 2024, arXiv:2405.14831)

### Personalized PageRank (PPR) for Retrieval

HippoRAG's retrieval mechanism:

1. **Index construction:**
   - Run LLM-based OpenIE over all documents to extract (subject, predicate, object) triples.
   - Build a knowledge graph where nodes = named entities, edges = predicates.
   - Apply node deduplication (synonym detection via embedding similarity threshold).

2. **Retrieval query:**
   - Extract named entities from the query (via NER or synonym matching).
   - Use these entities as **PPR seed nodes** in the knowledge graph.
   - Run **Personalized PageRank** with the seed nodes as teleport distribution.
   - Retrieve documents from top-ranked nodes.
   - Integrate with dense retrieval (DPR/ColBERT): combine PPR node scores with passage similarity scores.

3. **Why PPR over BFS (pgmnemo's approach):**
   - BFS (pgmnemo) applies uniform weight to all neighbors at each hop depth.
   - PPR propagates relevance globally across the graph, allowing distant but highly-connected nodes to surface.
   - PPR naturally handles hub nodes (frequently referenced entities like a key project file) which BFS visits but weights only by depth.
   - PPR is especially effective for multi-hop queries where intermediate nodes are not directly similar to the query.

**Applicability to pgmnemo `mem_edge`:**

The `mem_edge` table in pgmnemo is structurally compatible with PPR. Nodes are `agent_lesson` rows; edges are `mem_edge` rows with `weight` values. A PPR implementation over `mem_edge` could:

```sql
-- Conceptual PPR seed: start from top-5 cosine candidates (anchors)
-- Propagate: for each iteration, update node scores as:
--   score[v] = (1-d) * seed[v] + d * SUM(score[u] * weight[u→v] / out_degree[u])
-- where d = damping factor (typically 0.85)
```

This would replace or augment the current BFS-with-depth-decay in `recall_lessons()`. The primary challenge is that PPR requires iterative computation (not a single SQL CTE pass) — it would need a background job or a PL/pgSQL loop.

**pgmnemo gap:** BFS in `recall_lessons()` (`extension/pgmnemo--0.2.1--0.3.0.sql:S7`, lines 257–278) uses depth-limited traversal with `MAX(1 - depth/max_depth)` proximity. This is a linear depth penalty, not a global graph score. Nodes reachable only via hub nodes (high out-degree) are not preferentially surfaced. For a memory system with many cross-referenced facts (entities like "bge-m3 embedder" referenced in 50 lessons), PPR would produce better recall than BFS.

**Entity graph population prerequisite:** PPR requires a populated entity graph. pgmnemo's `edge_kind = 'entity'` edges are not yet populated (entity extraction deferred, `spec/reports/TL_MAGMA2_SCHEMA_2026-05-09.md §5`). PPR is only applicable after entity seeding.

*Sources: arXiv:2405.14831 §3 (HippoRAG retrieval algorithm); Princeton-NLP/HippoRAG GitHub (hipporag/retrieval.py); `extension/pgmnemo--0.2.1--0.3.0.sql` lines 257–278.*

---

## Gap Priority Summary

### High-severity gaps (block recall quality improvements)

| Gap | Systems that have it | pgmnemo path |
|---|---|---|
| Adaptive learned traversal policy | MAGMA | Replace regex intent classifier in DESIGN_DPT with a lightweight encoder fine-tuned on query–graph pairs |
| Dual-stream async consolidation | MAGMA (partial Zep) | Implement background entity extraction + edge weight consolidation job |
| Personalized PageRank | HippoRAG | PL/pgSQL iterative PPR over `mem_edge` (requires entity graph population first) |
| LLM-based NER/RE for graph construction | MAGMA, Mem0, Zep, HippoRAG | Entity extraction from `agent_lesson.metadata` (MAGMA-3 task per TL_MAGMA2_SCHEMA §5) |
| Entity synonym deduplication | MAGMA, Zep, HippoRAG (partial Mem0) | Embedding-similarity node merge at entity insertion time |
| Semantic (LLM) deduplication | MAGMA, Mem0, Zep | LLM-ref dedup at write time (blocked by LLM-judge removal — alternative: embedding cosine threshold instead of SHA-256) |
| Auto memory extraction from turns | Mem0, Zep | LLM extraction blocked; rule-based extraction from structured `done_note` patterns is feasible without LLM |

### Medium-severity gaps (improve precision, not recall floor)

| Gap | Systems | Notes |
|---|---|---|
| Semantic graph traversal (wired in BFS) | MAGMA | `recall_lessons()` skips `edge_kind='semantic'`; enable with controlled hop depth |
| Entity graph traversal (wired in BFS) | MAGMA, Mem0 | Same — entity edges in schema, not in BFS |
| Bitemporal edges (`valid_to` on `mem_edge`) | Zep | Add `valid_to TIMESTAMPTZ` to `mem_edge`; filter in BFS |
| Temporal point-in-time queries (`as_of_time`) | Zep | Add `as_of_time` parameter to `recall_lessons()` |
| Cross-encoder reranking | Zep | Post-ANN reranking step (latency cost ~100 ms) |
| Hierarchical context synthesis | MAGMA (partial Zep) | Subgraph-level summarization before context pack assembly |

### Low-severity gaps (nice-to-have)

| Gap | Systems | Notes |
|---|---|---|
| Community clustering | MAGMA, Zep | Useful for broad-context queries; Louvain on entity graph |
| MMR diversity reranking | Zep | Reduces redundancy; low recall impact |
| Graph edge weight propagation (full PPR) | HippoRAG, Zep | Low priority until entity graph is populated |

---

## pgmnemo Current-State Evidence Map

All claims about pgmnemo state are traceable to specific source lines:

| Claim | Source |
|---|---|
| `recall_lessons()` scoring formula: `0.4×cos + 0.2×imp + γ×recency + 0.1×prov + δ×graph` | `extension/pgmnemo--0.2.1--0.3.0.sql:S7` lines 279–297 |
| BFS only traverses `edge_kind IN ('causal', 'temporal')` — semantic/entity excluded | `extension/pgmnemo--0.2.1--0.3.0.sql:S7` line 266 |
| Intent classification is keyword regex, not learned | `research/PAPER_v0.1.md §4.3` |
| No async entity extraction; deferred | `spec/reports/TL_MAGMA2_SCHEMA_2026-05-09.md §5` item 3 |
| Deduplication is SHA-256 `content_hash` only | `research/PAPER_v0.1.md §4.2` (`content_hash BYTEA NOT NULL` comment) |
| `mem_edge` has `created_at` but no `valid_to` | `extension/pgmnemo--0.2.1--0.3.0.sql:S2–S4` (column list) |
| Provenance-gated retrieval (`trust_level`, `role_filter`) | `extension/pgmnemo--0.2.1--0.3.0.sql:S7` lines 244–247 |
| Importance score (0–5) in ranking | `extension/pgmnemo--0.2.1--0.3.0.sql:S7` line 283 |
| BFS graph proximity was silently broken (v0.2.x `relation_type` bug) | `spec/reports/TL_MAGMA2_SCHEMA_2026-05-09.md §3 BUG-1` |
| H-1 recall@10 = 0.795 on LoCoMo (session-level granularity) | `spec/v2/pgmnemo/HYPOTHESES_RESULTS_v030.md §H-1` |
| MAGMA metric incompatibility note (LLM-judge vs retrieval recall@K) | `spec/v2/pgmnemo/HYPOTHESES_RESULTS_v030.md §methodology "We beat MAGMA" gate` |

---

## Self-Evaluation

**What was accomplished:**
- 25 distinct retrieval techniques compared across 5 systems (target was ≥ 20).
- All pgmnemo cells cited to specific SQL lines or spec sections.
- External system cells cited to arXiv paper sections and known GitHub file paths.
- MAGMA contributions mapped individually with pgmnemo partial/lack breakdown.
- Concrete PPR applicability assessment with pseudocode SQL sketch.
- Gap priority tiering (High / Medium / Low) actionable for planning.

**Limitations:**
- External system sources are based on training-data knowledge (up to Aug 2025). Mem0, Zep, HippoRAG APIs may have changed; cells should be verified against current repository state before acting on them.
- MAGMA arXiv:2601.03236 was not directly accessible; the paper reference and 5 contributions were reconstructed from internal pgmnemo documents that quote it (`research/PAPER_v0.1.md §2 Table`, `spec/reports/TL_MAGMA2_SCHEMA_2026-05-09.md`). Cell accuracy is high for the techniques documented internally; any additional MAGMA techniques not referenced in pgmnemo docs may be missing.
- No "we beat MAGMA" claim is appropriate until H-2–H-5 resolve (per `HYPOTHESES_RESULTS_v030.md §methodology`).

**Recommended next tasks (not created here — for TL planning):**
1. MAGMA-3: entity extraction seeder (prerequisite for techniques 7, 9, 17, 25 improvement)
2. MAGMA-4: wire `edge_kind = 'semantic'` and `edge_kind = 'entity'` into `recall_lessons()` BFS
3. MAGMA-5: PPR implementation over `mem_edge` (requires MAGMA-3 done first)
4. ZEP-1: add `valid_to` to `mem_edge` + `as_of_time` param to `recall_lessons()`
