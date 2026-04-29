# ADR-001: Memory Service Substrate Selection

**Status:** PROPOSED  
**Date:** 2026-04-27  
**Research inputs:** R1 (RESEARCH_SOTA.md), R2 (RESEARCH_CURRENT_STACK_LIMITS.md)  
**Decision owners:** Founder (final), PI (recommendation)

---

## Context

Agentura v2 needs a memory microservice implementing five layers (ТЗ §6): Working, Episodic, Semantic, Procedural, Meta-cognitive. R2 audit identified 13 gaps in the current stack — the most critical being: no episodic retrieval (G-08), no entity/relation graph for knowledge linking, aggressive dedup destroying knowledge (G-03), and pure-Python O(n²) curation (G-06).

R1 SOTA scan shows production systems (Zep/Graphiti, Mem0, Cognee) converging on **vector + graph hybrid** substrates. The architectural question: which substrate implementation minimizes ops cost while enabling graph-structured memory queries and preserving the existing PostgreSQL investment?

### Constraints

| Constraint | Value |
|-----------|-------|
| Deployment model | Docker Compose, single-host (macOS dev machine) |
| Tenancy | Single-tenant personal EA |
| Current data volume | ~115 MB memory tables, ~10K memory rows, ~57K turn rows |
| Existing infra | PostgreSQL 17 + pgvector (11 HNSW/IVFFlat indexes, port 5433) |
| Budget | Minimal — TECON economy, no external managed services for MVP |
| Team | 1 founder + agent fleet (no dedicated DBA/SRE) |
| ACID requirement | Strong — phantom-DONE class bugs traced to eventual consistency |
| Target scale (12 months) | ~100K memory rows, ~500K turns, ~50 agents |

---

## Candidates

### Option 1: Neo4j + Neo4j Vector Indexes

The substrate recommended by ТЗ §18 and used by Zep/Graphiti and Mem0.

| Criterion | Assessment |
|-----------|------------|
| **Graph query expressiveness** | Excellent. Cypher is purpose-built; multi-hop, shortest-path, community detection, temporal traversal native. |
| **Retrieval latency (p95)** | ~300 ms (Graphiti benchmark). Neo4j vector indexes available since v5.11 (HNSW, cosine). |
| **Ops complexity** | High for single-dev. Requires separate container (~1.5 GB RAM baseline), JVM tuning, APOC plugins, separate backup strategy. Neo4j Community Edition has no clustering/HA. |
| **Cost** | CE free (GPLv3 viral license concern for proprietary code). Enterprise = $36K+/yr. Neo4j Aura managed = $65+/mo min. Docker self-host = ~2 GB additional RAM. |
| **Maturity** | Very high. Production-proven at scale. Active vector index development. |
| **Integration with existing PG** | Poor. Two-phase writes required (PG for tasks/runs/metadata + Neo4j for memory graph). No single ACID transaction. Requires saga pattern or eventual consistency. |
| **ACID transaction surface** | Separate from Postgres. Cross-DB consistency requires application-level coordination. |
| **Vendor lock-in** | High. Cypher is Neo4j-proprietary (ISO GQL standard exists but adoption nascent). Data export = JSON/CSV (no standard graph interchange). |

**Verdict:** Best graph capabilities, but violates single-ACID-surface constraint and adds significant ops burden for a personal assistant system. The benefit of Cypher's expressiveness is meaningful for complex traversals (multi-hop reasoning, community detection) but the current 10K-row dataset and single-tenant model don't justify the infrastructure cost.

---

### Option 2: PostgreSQL + pgvector + Apache AGE (or recursive CTEs)

Extend the existing PostgreSQL instance with graph capabilities.

| Criterion | Assessment |
|-----------|------------|
| **Graph query expressiveness** | Good (AGE) / Adequate (recursive CTE). AGE supports openCypher on PG — path traversal, variable-length edges, MATCH clauses. Recursive CTEs handle adjacency-list graphs with 3-5 hop limits efficiently. |
| **Retrieval latency (p95)** | <50 ms for current data volume (pgvector HNSW + btree joins). AGE adds ~10-20% overhead vs raw SQL for graph queries. At 100K rows: projected <100 ms. |
| **Ops complexity** | Low. AGE is a PG extension (`CREATE EXTENSION age`). No additional container. Same backup, same WAL, same monitoring. Recursive CTEs need zero extensions. |
| **Cost** | Zero incremental. Same PG instance, same Docker container RAM. AGE is Apache 2.0 — no license concern. |
| **Maturity** | AGE: Apache incubating → top-level project (2024). 2.4K stars. Used in production by Bitnine (commercial fork: AgensGraph). Recursive CTEs: PostgreSQL native since v8.4 (2009). |
| **Integration with existing PG** | Excellent. Same database, same connection pool, same SQLAlchemy/psycopg2 drivers. All 11 existing pgvector indexes preserved. Memory tables can JOIN directly with `tasks`, `agent_run`, `projects`. |
| **ACID transaction surface** | Unified. Graph writes + vector writes + metadata in a single PG transaction. No eventual consistency — prevents phantom-DONE class bugs by design. |
| **Vendor lock-in** | Low. openCypher (via AGE) is standardized. Data is in PG tables — standard pg_dump. Migration to Neo4j possible via COPY → LOAD CSV. |

**AGE vs recursive CTEs trade-off:**

| Feature | AGE (openCypher) | Recursive CTE |
|---------|-----------------|---------------|
| Variable-length path queries | Native: `MATCH (a)-[*1..5]->(b)` | Manual: `WITH RECURSIVE` + depth counter |
| Developer ergonomics | Cypher syntax (familiar from Neo4j docs) | Raw SQL (team already knows) |
| Index support | AGE creates GIN indexes on graph labels | Standard btree/GIN on adjacency columns |
| Extension install | `apt install postgresql-17-age` + `CREATE EXTENSION` | None required |
| Community size | 2.4K stars; smaller ecosystem | Universal PostgreSQL knowledge |
| Risk | Extension may lag PG major version upgrades | Zero risk — PG core |

**Verdict:** Best fit for MVP. Preserves existing investment, zero ops overhead, unified ACID, adequate graph expressiveness for 5-layer memory (entity relations, temporal edges, lesson→error linkage). AGE provides a Cypher-like query surface for when recursive CTEs become unwieldy.

---

### Option 3: Hybrid — Postgres (metadata) + Separate Graph Store + Separate Vector DB

The "best-of-breed" architecture used by Mem0 (PG + Neo4j + Qdrant).

| Criterion | Assessment |
|-----------|------------|
| **Graph query expressiveness** | Excellent (whichever graph DB is chosen). |
| **Retrieval latency (p95)** | Variable. Fan-out across 3 services → p95 dominated by slowest. Mem0 reports 91% lower vs full-context (not vs monolith DB). Network hop latency between containers. |
| **Ops complexity** | Very high. 3 containers (PG + Neo4j/Memgraph + Qdrant/Weaviate). 3 backup strategies. 3 upgrade paths. 3 monitoring surfaces. Unacceptable for 1-person team. |
| **Cost** | ~4-6 GB additional RAM (Neo4j ~2GB + Qdrant ~1GB + overhead). Embedding storage duplicated across PG and vector DB. |
| **Maturity** | Each component mature individually. Integration layer is custom — no standard orchestration. |
| **Integration with existing PG** | Poor. Must duplicate data or maintain sync. Existing 11 pgvector indexes wasted (migrate to dedicated vector DB). |
| **ACID transaction surface** | Fragmented across 3 systems. Consistency requires distributed saga. |
| **Vendor lock-in** | Medium. Polyglot persistence means each component is replaceable, but integration code is bespoke. |

**Verdict:** Over-engineered for single-tenant personal assistant at current scale. The ops burden is proportional to a team with dedicated SRE. Appropriate only if single-DB performance proves insufficient at >1M rows — unlikely within 12-month horizon.

---

### Option 4: Alternatives — Memgraph, ArangoDB, KuzuDB

| System | Graph | Vector | ACID | Ops complexity | Notes |
|--------|-------|--------|------|----------------|-------|
| **Memgraph** | Cypher-native, in-memory | Vector indexes (v2.18+, HNSW) | Single-node ACID | Medium (separate container, C++ binary, ~512MB RAM) | Free CE; faster than Neo4j for streaming/transactional workloads; smaller community (3K stars) |
| **ArangoDB** | AQL graph traversals + multi-model (doc + graph + search) | ArangoSearch with vector (since 3.12) | Multi-model ACID | Medium-high (JVM-like memory profile, complex config) | Apache 2.0; graph+doc+vector in one binary; BUT query language (AQL) is proprietary and different from Cypher/SQL |
| **KuzuDB** | Cypher-native, embedded (in-process) | No native vector index (requires external) | ACID (embedded) | Very low (single shared library, no container) | MIT license; embeds into Python process like SQLite; BUT no vector index means pgvector still needed separately; very young (2023, 1.5K stars) |

**Verdict (per alternative):**
- **Memgraph:** Viable but solves a problem we don't have (streaming graph analytics). Same ops overhead as Neo4j with smaller ecosystem.
- **ArangoDB:** Multi-model is attractive but AQL is a learning/migration burden. Community smaller than Neo4j.
- **KuzuDB:** Interesting for embedded graph (zero ops) but lacks vector indexes — still need pgvector for embeddings. Creates same two-system split as Option 1 without the graph-vector co-location benefit.

None of these alternatives provide a clear advantage over Option 2 (PG+pgvector+AGE) for our constraints.

---

## Decision Matrix

| Criterion (weight) | Option 1: Neo4j | Option 2: PG+pgvector+AGE | Option 3: Hybrid | Option 4: Best alt (Memgraph) |
|--------------------|:-:|:-:|:-:|:-:|
| Graph expressiveness (15%) | 5 | 3.5 (AGE) / 2.5 (CTE) | 5 | 5 |
| Retrieval latency p95 (15%) | 3 | 5 | 3 | 4 |
| Ops complexity (20%) | 2 | 5 | 1 | 2.5 |
| Cost (10%) | 2 | 5 | 1 | 3 |
| Maturity (10%) | 5 | 3.5 | 4 | 3 |
| PG integration (15%) | 1 | 5 | 2 | 1.5 |
| ACID unified (10%) | 1 | 5 | 1 | 2 |
| Vendor lock-in (5%) | 2 | 5 | 3 | 3 |
| **Weighted total** | **2.65** | **4.55** | **2.30** | **2.78** |

---

## Decision

**Recommended substrate for MVP: Option 2 — PostgreSQL + pgvector (existing) + Apache AGE extension.**

### Implementation approach (phased)

**Phase 1 (MVP, weeks 1-3):** Recursive CTEs + JSONB adjacency lists for entity-relation graph. No extension install. Graph schema as regular PG tables (`memory_node`, `memory_edge` with `source_id`, `target_id`, `relation_type`, `valid_from`, `valid_until`). pgvector HNSW for all embedding retrieval. Single-transaction write path.

**Phase 2 (hardening, weeks 4-6):** Install Apache AGE for Cypher-like queries when traversal depth > 3 hops or when community detection needed. Migrate graph tables to AGE-managed `ag_graph`. Add bitemporal validity columns (borrowing Graphiti pattern B1 from R1).

**Phase 3 (scale escape hatch, if needed):** If query latency degrades at >500K memory rows or graph depth >7 required, extract graph layer to Memgraph (Cypher-compatible, minimal migration) with PG remaining as source-of-truth for metadata/embeddings.

---

## Consequences

### Positive

1. **Zero infra change for MVP** — no new Docker container, no new backup strategy, no additional RAM.
2. **Unified ACID** — memory writes (graph + vector + metadata) in a single PG transaction. No phantom-consistency bugs.
3. **Existing investment preserved** — all 11 pgvector HNSW indexes, all existing tables, all existing SQLAlchemy models usable from day 1.
4. **Low latency** — co-located graph + vector in same DB. No network hop for hybrid retrieval. Expected p95 < 50ms at current scale, < 100ms at 100K rows.
5. **Operational simplicity** — one `pg_dump` backs up everything. One `alembic upgrade` migrates everything. One connection pool.
6. **Migration path preserved** — if graph expressiveness proves insufficient, AGE uses openCypher which maps directly to Neo4j/Memgraph Cypher. Data in PG tables = trivial to export.

### Negative

1. **Graph expressiveness ceiling** — recursive CTEs are verbose for >3 hop traversals. Community detection (label propagation) would need custom PL/pgSQL. AGE mitigates but is less mature than Neo4j.
2. **No native streaming graph analytics** — algorithms like PageRank, Louvain, node2vec require `pgvector` hacks or external computation. Acceptable: none of these are MVP requirements.
3. **AGE extension maturity risk** — if AGE lags PostgreSQL 18+ upgrades, Phase 2 may require extension fork or fallback to recursive CTEs.
4. **Monolithic DB risk** — memory workload shares connection pool and I/O with tasks/runs/analytics. At high load, memory queries could contend. Mitigation: dedicated read replica or separate schema with own pool (still same PG instance).

### Neutral

- The decision does NOT preclude adding Neo4j later (Phase 3 escape hatch). The graph schema (nodes + edges + temporal columns) is portable.
- This decision applies to MVP (target: 12 months). Re-evaluate at 500K memory rows or if multi-hop traversal depth >5 becomes a critical retrieval pattern.

---

## Alternatives Considered but Rejected

| Alternative | Reason for rejection |
|-------------|---------------------|
| Neo4j (Option 1) | Ops overhead (JVM, separate container, separate backup) disproportionate to single-tenant scale. Violates unified ACID constraint. GPLv3 license concern for CE. |
| Full hybrid (Option 3) | 3-container polyglot persistence unmanageable for 1-person team. Integration code > substrate benefit at <100K rows. |
| Memgraph (Option 4) | Same ops overhead as Neo4j, smaller community, solves streaming analytics problem we don't have. |
| ArangoDB (Option 4) | Proprietary query language (AQL), smaller ecosystem, no migration path to Neo4j if needed later. |
| KuzuDB (Option 4) | No vector indexes — still needs pgvector. Two-system split without the co-location benefit. Too immature (2023). |
| Qdrant/Weaviate standalone | Duplicates what pgvector already does. Adds container. No graph capability. |

---

## Open Questions

| # | Question | Impact | Resolution path |
|---|----------|--------|-----------------|
| Q1 | Does AGE support PG 17? | Phase 2 blocker if no. | Check AGE compatibility matrix; PG 17 support confirmed in AGE 1.5.0 (Dec 2024). |
| Q2 | What embedding dimension to standardize on? | Index efficiency. R2 found inconsistent dimensions possible. | Decide in ADR-002 (Embedding Strategy). Likely 1024 (voyage-3-lite) or 768 (bge-m3). |
| Q3 | Is recursive CTE performant enough for "lesson→addresses→error→caused_by→run" 4-hop chain? | Phase 1 viability. | Benchmark with synthetic 100K-row dataset before Phase 2 decision. |
| Q4 | How to handle bitemporal validity (Graphiti B1 pattern) in pure PG? | Core memory quality. | Two timestamp pairs per edge (`valid_from`/`valid_until` for real-world time, `created_at`/`superseded_at` for system time). Standard PG temporal patterns. |
| Q5 | Connection pool contention at scale — when to split? | Operational ceiling. | Monitor with pg_stat_statements. Split at p95 > 200ms on memory queries. |

---

## References

- R1: `spec/v2/memory-svc/RESEARCH_SOTA.md` — 7-system comparative table, patterns B1-B3, anti-patterns A1-A3
- R2: `spec/v2/memory-svc/RESEARCH_CURRENT_STACK_LIMITS.md` — 13 gaps, existing pgvector infrastructure baseline
- Apache AGE: https://age.apache.org/ (Apache 2.0, PG extension for openCypher)
- pgvector HNSW benchmarks: https://github.com/pgvector/pgvector (ann-benchmarks integration)
- Graphiti bitemporal model: arXiv:2501.13956 §3.2
- Mem0 architecture: arXiv:2504.19413 §3
- PostgreSQL recursive CTEs: https://www.postgresql.org/docs/17/queries-with.html
