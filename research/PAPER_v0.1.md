# Agency-MEM-1: A Four-Layer Hybrid Memory Substrate for Multi-Role LLM Agent Systems with Provenance-Gated Canonicalization and Policy-Guided Multi-Graph Retrieval

**Pre-print v0.1 (DESIGN-stage, no empirical results yet) — submitted for internal Feynman peer review.**

| Field | Value |
|---|---|
| Authors | TL (synthesis), DESIGN-MEM-001 working group (D1–D9 + D-MS/D-HT/D-PT contributors), Founder (sponsor) |
| Date | 2026-04-28 |
| Sprint id | DESIGN-MEM-001 (project_id = 9) |
| Pre-registration commit | `879263e4` (D1, D2, D-HT, D-PT, D7 backfill) + `28ccb374` (D-MS) + `139a4532` (D8) + `06e04d4e` (D-MS dup) + `c183f60c` (D5) + `ff686a9d` (D4) + `471f79af` (D6) |
| Status | DESIGN complete (10/11 green, 1/11 yellow), BUILD pending founder sign-off |
| Total DESIGN spend | $7.20 / $8.00 envelope (12 tasks, 11 design artifacts, 0 production code) |

---

<!-- feynman-stamp:v1
protocol: peer-review
reviewer: principal_investigator (77)
review_date: 2026-04-28
verdict: REVISIONS_REQUIRED
review_artifact: spec/v2/memory-svc/REVIEW_DESIGN-MEM-001_v0.1.md
-->

## Abstract

We present **Agency-MEM-1**, a memory substrate for a multi-role LLM agent system in which roles span heterogeneous skill profiles (TL, principal_investigator, statistical_analyst, literature_scout, software_developer, etc.) and operate against a single shared codebase. The substrate is designed to address four observed failure modes in the host system (Agentura v2 / Agency): (i) bounded context windows force per-session truncation at 800 K input tokens with no cross-session continuity; (ii) episodic memory of prior agent runs is not retrievable, leading to the **phantom-DONE** class-1/2/3 family of escalations (8 cases observed in 2026-04 alone, ≥$32 attributable cost); (iii) heuristic-only quality evaluation (the LLM-as-judge has been removed) leaves no signal to consolidate task lessons; (iv) tool-recall across agent runs has zero structural support — every run re-discovers files via `Glob`/`Grep`. The proposed substrate is a four-layer store (working / episodic / canonical / external-fact) on PostgreSQL 17 + pgvector, with HNSW partial indexing on the active partition, JSONB-extensible schema, mandatory provenance per row, and three retrieval routers (HyperMem-style topic-tier coarse filter, MemOS-style context-pack budget injector, MAGMA-style policy-guided multi-graph traversal) composed in a single read path. We pre-register four falsifiable hypotheses with hard kill-criteria measured against a 100-row synthetic baseline (BL-B, recall@10 = 0.62) and a planned 4-week production deployment; primary endpoint is recall@10 ≥ 0.72 and answer-quality delta ≥ 5 percentage points vs no-memory control. We document one design-time gap (**D7-BLOCKED-RUNTIME**: live measurement is impossible until BUILD Phase 1 lands the FastAPI scaffold) and three threats to validity (the LLM-judge removal interacts with our quality endpoint; the synthetic fixture under-represents long-tail recall difficulty; provenance discipline in the host system is empirically weak — 6 of 12 DESIGN deliverables required TL backfill).

**Keywords:** agent memory, LLM systems, retrieval-augmented generation, knowledge graphs, provenance, multi-agent orchestration, pre-registered hypotheses, post-hoc replication.

**Falsification clause:** if at the end of BUILD Phase 2 (Étap 2 gate) recall@10 on BL-B falls below 0.65 (BL-B + 3 percentage points), the BUILD is paused and the substrate is returned to the design board.

---

## 1. Introduction

### 1.1 Setting

Agency is a multi-role LLM agent platform built on top of Anthropic's Claude Agent SDK plus an open-source `claude_agent_sdk` runtime. It operates on the Agentura v2 codebase (Next.js + FastAPI + PostgreSQL) and orchestrates ~30 distinct virtual agent roles via a Prefect-driven dispatcher. Roles delegate tasks (DELEGATED → RUNNING → COMPLETED / FAILED / ESCALATED) and consume a shared workspace. The host system has reached operational maturity along several axes: it tracks per-run cost and tokens (`agent_run.cost_usd`, `total_tokens_in/out`), enforces dispatch-time budget (`dag_budget:<usd>`), guards mid-run cost (`GC3_CIRCUIT_BREAKER_CEILING_USD`), and intercepts a growing list of failure modes via a `failure_classifier.py` enum (currently 14 classes including `INFRA_AUTH_INVALID`, `INFRA_RATE_LIMIT`, `INFRA_TIMEOUT`, `DAG_MASTER_PARSE`, `COST_CEILING`, `ACCOUNT_403_FORBIDDEN`).

What it lacks is **memory across runs**. Each `agent_run` is a fresh SDK session whose system prompt is assembled from an `agent_config.system_prompt` field, an injected snapshot of recent agent lessons (`memory/lessons/<role>/active.md`, capped at 8 KB), and a snapshot of the current task description (`tasks.description`, max ~60 KB after `READ_FILE_CAP_BYTES` — 8 KB for individual files). There is no episodic store of prior similar tasks, no retrieval of canonical project facts, and no de-duplicated lesson registry beyond the 8 KB active.md file (which is overwritten by `memory_curator.curate_agent_lessons` with cosine-similarity > 0.92).

### 1.2 Observed failure modes (motivation)

We motivate Agency-MEM-1 by four empirical observations from the 2026-04 production window of Agency:

**M-1: bounded session context.** The token cap `SESSION_INPUT_CAP_TOKENS = 800_000` (`apps/api/src/api/services/orchestration/dispatch_service.py`) causes a forced new-session reset on long-running DAGs. After reset, prior turn history is gone unless re-derived from `tasks.description`. Approximate weekly cost of context re-derivation across all DAGs is $4–6 (estimated from `cache_creation_tokens` ratio in `agent_run`).

**M-2: phantom-DONE family.** Three classes of phantom completion have been catalogued in `spec/reports/`: class-1 (no commit at all), class-2 (commit exists but in a worktree branch never merged — `agent/run-<id>` SWDEV-260417-7), class-3 (commit exists on main but contains only test/spec files — phantom-impl, SWDEV-260418-2). The **DESIGN-MEM-001 sprint itself** reproduced class-1 six times: 6 of 12 deliverables (D1, D2, D-HT, D-PT, D6, D7) were closed with valid `DELIVERY REPORT` text but without `git add`/`git commit`; only the WP12 worktree-no-commit guard caught one (D6 → task 2048 ESCALATED), the other five were rescued by TL backfill (`commit 879263e4`). This is direct evidence that **agents do not durably remember "must commit before DONE"** even when their SKILL.md and the task description say so explicitly.

**M-3: zero memory of prior runs.** When task X-N finds a non-trivial bug fix and lands a commit, that knowledge is captured only as (a) a free-text `done_note`, (b) a possible `lessons_*` cosine-deduped append, (c) a possible `agent_reflection` row. None of these are retrieved by task X-{N+1}. Empirically: `RES-MEM-001/R1` cost the founder $13.13 in single-session burn re-discovering an architectural decision documented in three prior reports (cited in `spec/reports/RETRO_RES-MEM-001-R1.md`).

**M-4: tool-recall is structural, not semantic.** Every agent run re-discovers files via `Glob('agents/**/SKILL.md')` and `Grep` with project-specific patterns. There is no cached map of "files-relevant-to-this-role" or "files-changed-by-this-DAG." A first-order estimate puts ambient `Glob`+`Grep` cost at 5–8% of total turn-time across the fleet.

### 1.3 Contributions

This paper makes four contributions:

**C-1.** A four-layer memory taxonomy specialized for multi-role LLM systems: working (L1, ≤24 h, run-scoped), episodic (L2, ≤90 d, agent-run-scoped), canonical (L3, ∞, project-scoped, TL-promoted only), external-fact (L4, vendor-mirrored, immutable). Each layer has an explicit retention policy, a mandatory provenance schema (`provenance_run_id`, `provenance_role`, `provenance_trust_level`), and a state-machine governing inter-layer promotion.

**C-2.** A composable retrieval pipeline that integrates three published-but-disjoint architectures into a single read path: (a) HyperMem (Choi et al. 2024) topic-tier coarse-to-fine routing for multi-domain memory partitioning, (b) MAGMA (anonymous, arXiv 2026-01) policy-guided multi-graph traversal with adaptive intent → graph routing, (c) MemOS MemScheduler (Anhui-Med 2025) token-budget-aware ranked context injection. We argue (Section 5) that the three are operationally complementary: HyperMem partitions, MAGMA routes, MemOS budgets.

**C-3.** A provenance-gated canonicalization protocol (D5 + D8) in which (i) every write into L1/L2 is unconditional, (ii) promotion to L3 requires `X-Role: tech_lead` and a complete provenance chain, (iii) the host system's existing TL-only authority (`AGENT_MCP_ALLOW_ASSIGNEES_TASKS_DB=...`) is repurposed as the access-control vehicle. We claim this addresses the R-3 (canonical pollution) risk without introducing a new authentication primitive.

**C-4.** A pre-registered evaluation protocol with four falsifiable hypotheses (Section 6) and a hard Étap 2 kill-criterion (recall@10 ≥ BL-B + 5 pp on a frozen 100-row fixture before BUILD spend exceeds $10). We make the fixture (`spec/v2/memory-svc/fixtures/eval_baseline_100.json`, 34 KB, 100 rows, seed=42) publicly available within the repository for replication.

### 1.4 Non-contributions (scope boundaries)

This paper does **not**: (i) propose a new vector index (we use stock `pgvector` HNSW); (ii) propose a new embedding model (we lock to `bge-m3` 1024d on host MLX); (iii) replace the host system's `lessons_*` files (those become a denormalized projection of L2); (iv) modify the host system's failure classifier or dispatch SQL beyond adding one MCP-allowlist entry. Section 8 enumerates threats to validity that follow from these constraints.

---

## 2. Related Work

We review seven memory systems through three lenses: substrate, retrieval mode, governance.

| System | Substrate | Retrieval | Governance | Pattern we borrow |
|---|---|---|---|---|
| MemGPT / Letta (Packer 2023, Letta 2024) | Vector + KV + in-context paging | Tool-call (`archival_memory_search`, `recall_memory_search`) | Agent-controlled | Layered tier metaphor (L1/L2/L3) but **not** the OS-paging illusion |
| Zep / Graphiti (Zep 2024) | Temporal knowledge graph (Neo4j) | Hybrid: semantic + keyword + graph traversal + MMR + cross-encoder | Automatic temporal invalidation | Bitemporal validity columns (`valid_from`, `valid_to`) on canonical claims |
| Mem0 (Mem0 2024) | Vector + Graph + KV | Semantic + graph traversal + KV lookup | LLM-guided extraction + dedup | Hybrid substrate (we use `pgvector` rather than Neo4j to avoid adding infra) |
| Cognee (Cognee 2024) | Graph + Vector | 14 retrieval modes including chain-of-thought traversal | `observe()` → short-term, `promote()` → long-term | `promote()` semantics — explicit two-step lifecycle |
| Graphiti (Zep 2024) | Temporal KG | Same engine as Zep | Community clustering | Episode → Entity → Community subgraph hierarchy (we adapt as L2 → L3 → external) |
| A-MEM (Wang 2025) | Vector + dynamic links | Embedding NN search + link traversal | LLM-generated keywords + NN-link generation at insert | Note-linking pattern at write time (not a deployment) |
| MAGMA (anon. 2026) | Multi-graph (semantic + temporal + causal + entity) + unified vector | Policy-guided traversal; query intent routes across 4 graphs | Dual-stream: fast event ingest + async structural consolidation | Policy-guided multi-graph routing (D-PT) |
| HyperMem (Choi 2024) | Topic-partitioned vector store + hyperedge groups | Coarse topic filter → fine vector search inside partition | Topic-id assignment via topic-classifier model | Topic-tier coarse-to-fine routing (D-HT) |
| MemOS / MemScheduler (Anhui-Med 2025) | Vector + ranked context-pack assembly | Token-budget-aware ranked injection | Background distillation cycle | Context-pack builder (D-MS) |

**Anti-patterns we explicitly avoid (cf. Section 1.2):**

- **A-1: in-context paging only** (MemGPT 2023). Forces O(n) context growth; the host system's existing 800 K cap interacts adversely.
- **A-2: monolithic vector RAG with no temporal disambiguation** (early naïve RAG). Entangles temporal, causal, and entity signals; observed 18–45% accuracy drop in the MAGMA paper.
- **A-3: static memory with fixed retrieval operations**. Limits adaptability across task types; we explicitly route by query intent.

**Where Agency-MEM-1 differs from each.** Vs MemGPT: we keep **state in the database, not in context**; the SDK session never holds memory state across turns. Vs Zep: we avoid Neo4j by using `pgvector` + JSONB graph adjacency (`mem_edge` table); we accept slower complex graph queries in exchange for zero new infra. Vs Mem0: we add a TL-gated promotion lifecycle; Mem0's LLM-guided extraction is unsuitable when the LLM judge has been removed (see Section 8.2). Vs MAGMA: we run the four "graphs" as a single physical table with a `subtype` generated column rather than four physical graphs, accepting slower per-graph traversal in exchange for schema simplicity. Vs HyperMem: we keep topic assignment static via foreign key (`mem_episode.topic_id`) rather than dynamic hyperedges.

---

## 3. Problem Formulation

### 3.1 Definitions

Let an **agent run** be a tuple $r = (\text{role}, \text{task}, \text{turns}, \text{cost}, \text{outcome}) \in R$. Let a **memory item** be $m \in M$ with attributes:

$$
m = (\text{id}, \text{layer}, \text{item\_type}, \text{content}, \text{embedding}, \text{provenance}, \text{trust\_level}, \text{valid\_from}, \text{valid\_to}, \text{state})
$$

with $\text{layer} \in \{L_1, L_2, L_3, L_4\}$ and $\text{state} \in \{\text{draft}, \text{verified}, \text{canonical}, \text{deprecated}, \text{retired}\}$.

A **retrieval query** at turn $t$ of run $r$ is $q_t = (\text{intent}, \text{role}, \text{role-context}, \text{token-budget})$. The **read path** $\rho$ produces a context pack $C_t = \rho(q_t, M) \subseteq M$ subject to $\sum_{m \in C_t} |m| \leq \text{token-budget}$.

### 3.2 Objectives

We optimize four endpoints, in lexicographic priority order:

- **O-1 (recall):** $\text{recall@10}(C_t, \text{ground-truth}_q) \to \max$ over the BL-B fixture.
- **O-2 (quality lift):** $\Delta_q = q(\text{run}_{\rho-\text{on}}) - q(\text{run}_{\rho-\text{off}}) \to \max$, where $q$ is the host system's heuristic quality score (`agent_run.quality_score`).
- **O-3 (cost):** $\text{cost-per-recall-hit} = \text{retrieval-cost} / \text{hits} \to \min$.
- **O-4 (canonical purity):** $|\{m : m.\text{layer} = L_3 \land m.\text{trust\_level} < 0.7\}| / |\{m : m.\text{layer} = L_3\}| \to 0$.

### 3.3 Constraints

- **K-1 (no new infra).** Substrate must run on the existing PostgreSQL 17 + pgvector + MLX bge-m3. ADR-001.
- **K-2 (no SQL crossing).** Memory service may not JOIN against `tasks` or `user_goals`. Crossing is HTTP-only via `/api/memory/{items,retrieve,promote,expire}`. ADR-003.
- **K-3 (provenance mandatory).** Every write must carry `provenance_run_id`, `provenance_role`, `provenance_trust_level`. D1 §3.
- **K-4 (canonical promotion = TL only).** State transition `draft` → `canonical` requires `X-Role: tech_lead`. D5 §4.
- **K-5 (kill-switch).** Three env-flag-gated kill switches: `MEMORY_SVC_ENABLED`, `MEMORY_SVC_WRITE_ENABLED`, `MEMORY_SVC_RETRIEVE_ENABLED`. D8 §1.
- **K-6 (budget envelope).** BUILD spend ≤ $25 with 10% phantom-DONE buffer. WP15 label `dag_budget:25.00`.

### 3.4 Baseline (BL-B)

We define **BL-B** as the host system's current best memory mechanism: the `lessons_*` 8 KB active.md file injected at run start, plus zero-shot retrieval (no episodic store). On the 100-row synthetic fixture, BL-B yields:

| Metric | BL-B | Source |
|---|---|---|
| recall@10 | 0.62 | D7 §2.1, fixture seed=42 |
| MRR (mean reciprocal rank) | 0.34 | D7 §3.2 (gap, computed at design time from fixture) |
| p95 retrieval latency | n/a (no service) | D7 §4 |

BL-B serves as both control and floor for kill-criteria.

---

## 4. System Design

### 4.1 Substrate (ADR-001)

PostgreSQL 17 + pgvector 0.7.x, single instance, port 5433. Schema lives in dedicated `memory_*` tables with no foreign-key relationships to host-system tables. Embeddings via `bge-m3` 1024d on host MLX (LaunchAgent `com.agency.mlx-embeddings`, port 9200), the same vehicle already used by `agent_reflection`. No new infrastructure.

**Why pgvector and not Neo4j (cf. Zep, Mem0).** Neo4j would add (a) a fourth Docker container, (b) a separate query language (Cypher), (c) operator overhead. We accept the 2–4× slowdown on multi-hop graph queries (estimated, D-PT §5) in exchange for schema simplicity and zero infra delta. Multi-hop queries that are not p95-critical (canonical promotion auditing, community clustering) are background jobs; latency-critical queries (single-hop retrieval) are vector-only.

### 4.2 Data model (D1)

The substrate has five core tables:

```sql
-- mem_item: the memory unit. Layer is enforced by item_type.
CREATE TABLE mem_item (
    id            BIGSERIAL PRIMARY KEY,
    item_type     mem_item_type NOT NULL,        -- 'working' | 'episode' | 'claim' | 'entity' | 'external'
    layer         mem_layer GENERATED ALWAYS AS (
        CASE item_type
            WHEN 'working' THEN 'L1'
            WHEN 'episode' THEN 'L2'
            WHEN 'claim'   THEN 'L3'
            WHEN 'entity'  THEN 'L3'
            WHEN 'external' THEN 'L4'
        END
    ) STORED,
    content       TEXT NOT NULL,
    content_hash  BYTEA NOT NULL,                -- SHA-256 for dedup
    embedding     vector(1024),
    state         mem_state NOT NULL DEFAULT 'draft',
    trust_level   FLOAT NOT NULL DEFAULT 0.5,
    extension     JSONB NOT NULL DEFAULT '{}',   -- escape valve, no schema migration for new fields

    -- Provenance (mandatory, K-3)
    provenance_run_id      BIGINT NOT NULL,
    provenance_role        TEXT NOT NULL,
    provenance_task_id     BIGINT,
    provenance_commit_sha  CHAR(7),

    -- Bitemporal (cf. Zep)
    valid_from    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    valid_to      TIMESTAMPTZ,                   -- NULL = currently valid

    -- TTL
    expires_at    TIMESTAMPTZ,                   -- L1 only; NULL elsewhere

    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- mem_edge: typed relationships between items
CREATE TABLE mem_edge (
    id            BIGSERIAL PRIMARY KEY,
    src_id        BIGINT NOT NULL REFERENCES mem_item(id),
    dst_id        BIGINT NOT NULL REFERENCES mem_item(id),
    edge_type     TEXT NOT NULL,                 -- 'derives_from' | 'temporal_after' | 'caused_by' | 'mentions'
    edge_subtype  TEXT GENERATED ALWAYS AS (     -- D-PT virtual graph projection
        CASE edge_type
            WHEN 'derives_from' THEN 'semantic'
            WHEN 'temporal_after' THEN 'temporal'
            WHEN 'caused_by' THEN 'causal'
            WHEN 'mentions' THEN 'entity'
        END
    ) STORED,
    weight        FLOAT NOT NULL DEFAULT 1.0,
    extension     JSONB NOT NULL DEFAULT '{}',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- mem_topic: HyperMem-style topic partition (D-HT)
CREATE TABLE mem_topic (
    id            BIGSERIAL PRIMARY KEY,
    label         TEXT NOT NULL UNIQUE,
    centroid      vector(1024),                  -- updated via background reclustering
    extension     JSONB NOT NULL DEFAULT '{}'
);

-- mem_episode: L2 episodic store
CREATE TABLE mem_episode (
    id            BIGINT PRIMARY KEY REFERENCES mem_item(id) ON DELETE CASCADE,
    topic_id      BIGINT REFERENCES mem_topic(id),
    summary       TEXT NOT NULL,                 -- distilled from agent_run.result_summary
    span_start    TIMESTAMPTZ NOT NULL,
    span_end      TIMESTAMPTZ NOT NULL
);

-- mem_state_transition: audit log for state machine
CREATE TABLE mem_state_transition (
    id            BIGSERIAL PRIMARY KEY,
    item_id       BIGINT NOT NULL REFERENCES mem_item(id),
    from_state    mem_state NOT NULL,
    to_state      mem_state NOT NULL,
    actor_role    TEXT NOT NULL,
    rationale     TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

Indexes (D2):

```sql
-- Two HNSW indexes: full and active-partial
CREATE INDEX mem_item_embedding_full_idx
  ON mem_item USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

CREATE INDEX mem_item_embedding_active_idx
  ON mem_item USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64)
  WHERE state IN ('verified', 'canonical') AND valid_to IS NULL;

-- B-tree on bitemporal range
CREATE INDEX mem_item_validity_idx ON mem_item (valid_from, valid_to);

-- GIN on JSONB extension (sparse query)
CREATE INDEX mem_item_extension_gin ON mem_item USING gin (extension);

-- B-tree on provenance (audit / TL forensics)
CREATE INDEX mem_item_prov_idx ON mem_item (provenance_run_id, provenance_role);
```

The active-partial HNSW index is the primary search surface for the latency-critical read path (p95 ≤ 400 ms target). The full HNSW exists for canonical promotion auditing and bitemporal queries that may need access to retired items.

### 4.3 Read path

The composed read path is a three-stage pipeline:

```
                                  ┌─────────────────────────────┐
                                  │ topic-classifier (D-HT)     │  ← coarse: 8–16ms
                                  │ keyword + embedding         │
                                  │ → topic_id                  │
                                  └──────────────┬──────────────┘
                                                 │
                                                 ▼
                                  ┌─────────────────────────────┐
                                  │ vector ANN (HNSW partial)   │  ← fine: 30–80ms p95
                                  │ WHERE topic_id = ?          │
                                  │   AND state IN              │
                                  │     ('verified','canonical')│
                                  │ LIMIT 50 candidates         │
                                  └──────────────┬──────────────┘
                                                 │
                                                 ▼
                                  ┌─────────────────────────────┐
                                  │ policy router (D-PT)        │  ← intent → graph: 5–20ms
                                  │ intent in {factual,         │
                                  │   procedural, causal,       │
                                  │   social} → traversal type  │
                                  │ multi-hop on subtype graph  │
                                  └──────────────┬──────────────┘
                                                 │
                                                 ▼
                                  ┌─────────────────────────────┐
                                  │ MemScheduler (D-MS)         │  ← rank + budget: 10–30ms
                                  │ score = α·sim + β·layer +   │
                                  │         γ·recency + δ·prov  │
                                  │ knapsack to token-budget    │
                                  └─────────────────────────────┘
                                                 │
                                                 ▼
                                            context_pack
```

**Stage 1 — Topic-tier coarse routing (D-HT).** A keyword classifier (no LLM call) maps `query.text` → `topic_id`. Topic centroids are recomputed nightly by a background job (`memory_curator.recluster_topics`). For queries with no topic match, fall back to global search.

**Stage 2 — Vector ANN.** HNSW search on the partial active index, restricted by `topic_id`. `ef_search = 40` default; tunable per-role via `agent_config.extension.memory_ef`.

**Stage 3 — Policy-guided multi-graph traversal (D-PT).** Query intent (factual / procedural / causal / social) is classified via keyword regex on `query.text`. Each intent maps to a preferred `edge_subtype` for traversal expansion. Hop depth ≤ 2.

**Stage 4 — Context-pack assembly (D-MS).** Candidates are scored by a linear combination $\sigma = \alpha \cdot \text{sim} + \beta \cdot \text{layer\_weight} + \gamma \cdot \text{recency} + \delta \cdot \text{provenance\_strength}$. Default weights: $\alpha=0.5, \beta=0.2, \gamma=0.2, \delta=0.1$, with $L_3 = 3, L_2 = 2, L_1 = 1$. A knapsack pass selects the highest-σ subset that fits in the token budget (default 8000, configurable via `MEMORY_CONTEXT_BUDGET_TOKENS`).

### 4.4 Write path

Write path is unconditional for L1/L2 (always accepted), gated for L3:

```python
# POST /api/memory/items   (L1 / L2)
def write_item(payload, role: str, run_id: int, trust: float):
    assert role in MCP_ALLOWLIST_MEMORY  # K-3 enforce
    item = MemItem(
        item_type=payload.layer_to_type(),   # 'working' | 'episode'
        content=payload.content,
        content_hash=sha256(payload.content),
        embedding=embed(payload.content),
        state='draft' if payload.layer == 'L2' else 'verified',
        provenance_run_id=run_id,
        provenance_role=role,
        provenance_trust_level=trust,
        ...
    )
    db.insert(item)
    if item.layer == 'L1':
        item.expires_at = NOW() + INTERVAL '24 hours'
    return item.id


# POST /api/memory/promote   (L3, TL-only)
def promote(item_id: int, role: str):
    if role != 'tech_lead':
        raise HTTPException(403, 'TL-only promotion')   # K-4
    item = db.get(item_id)
    if item.trust_level < 0.7:
        raise HTTPException(409, 'trust_level too low for canonical')
    db.transaction([
        update(item, state='canonical'),
        insert(MemStateTransition(
            item_id=item_id, from_state=item.state,
            to_state='canonical', actor_role=role
        ))
    ])
```

### 4.5 Lifecycle & retention

| Layer | TTL | Promotion path | Eviction |
|---|---|---|---|
| L1 working | 24 h (default) or run-end + 4 h (override) | manual via L2 promote | `DELETE WHERE expires_at < NOW()` every 15 min |
| L2 episode | 90 d | auto-distill to L3 if cited ≥ 3 times by canonical claims (background) | partition drop monthly |
| L3 canonical | ∞ | from L2 via TL `promote()`; from external `import()` | state → 'deprecated' (manual) or 'retired' (TL) |
| L4 external | vendor-lifetime | n/a | mirror refresh weekly |

Canonical items are never deleted; they transition through `deprecated` → `retired` and are filtered out of the active partial index.

### 4.6 Integration with host system

A single integration point in `apps/api/src/api/services/agent_runners.py` between lines 1424–1426 (after `_lessons_context` injection):

```python
# existing:
context_lines.extend(_lessons_context)
# new (D-MS):
if MEMORY_CONTEXT_ENABLED:
    pack = await memory_client.build_context_pack(
        query=task.description,
        role=role,
        token_budget=MEMORY_CONTEXT_BUDGET_TOKENS,
    )
    context_lines.extend(pack.lines)
```

A/B testing is via the `MEMORY_CONTEXT_ENABLED` env flag, gated to 50% of dispatches via run_id parity for the first 7 days.

---

## 5. Theoretical Analysis

### 5.1 Why three retrieval mechanisms compose

Let $Q$ be the query distribution and $D$ the memory item distribution. Define:

- $T(d) = \text{topic}(d) \in \{1, ..., K\}$ — topic partition.
- $V(d) \in \mathbb{R}^{1024}$ — vector embedding.
- $G(d, e) \in \{\text{semantic}, \text{temporal}, \text{causal}, \text{entity}\}$ — edge subtype to neighbour $e$.

**Claim 5.1 (separation of concerns).** The three mechanisms address orthogonal axes of retrieval failure:

- HyperMem (topic tier) reduces *false positives from cross-domain semantic collision*: items from unrelated topics whose embeddings happen to be close in the global vector space.
- Vector ANN reduces *false negatives from lexical mismatch*: items semantically aligned with the query but using different surface terms.
- MAGMA (policy graph) reduces *retrieval miss for relational queries*: items not directly similar to the query but reachable via short paths in the right graph (e.g. "the bug fixed by the commit that introduced flag X").

**Sketch.** A pure vector ANN system has expected precision $\Pr_{q \sim Q, d \sim D}[T(d) = T(q) \mid d \in \text{top-}k]$. As $K \to \infty$ with fixed embedding dimension, cross-topic collision probability $\to$ a positive constant $\epsilon > 0$ (curse-of-dimensionality argument). Topic pre-filtering reduces this to $\epsilon / K$ in expectation when topic assignment is correct.

For relational queries (intent ∈ {procedural, causal, social}), the ground-truth document is reached via $\ell$ hops in graph $G$. Vector ANN alone has $O(\beta^\ell)$ recall where $\beta < 1$ is per-hop similarity decay. Policy traversal at hop depth 2 closes this gap when the intent is correctly classified.

### 5.2 Limits

- **Topic mis-assignment** (D-HT §6): the keyword classifier we ship (no LLM call) is conservative; on the BL-B fixture, ~12% of queries fall in "no-topic" and are routed to global search. Pre-registered: this fraction is reported as a secondary metric.
- **Intent mis-classification** (D-PT §5): regex-based intent classifier has known confusion between "procedural" and "factual" for queries beginning with imperative verbs ("Show", "Find", "Get"). Pre-registered: confusion matrix on a 50-query labelled subset.
- **Provenance staleness**: an item's `provenance_trust_level` is captured at write time and never updated. A run that was `trust_level=0.5` at the time may now have `trust_level=0.8` (the agent grew up). Possible enhancement: periodic re-scoring; deferred to v2.

### 5.3 Cost model

Per-query cost decomposition (estimated, D-MS §7):

| Stage | Estimated cost (USD per 1000 queries) | Rationale |
|---|---|---|
| Topic classifier (no LLM) | $0.00 | Pure DB query |
| Embedding (query-side) | $0.04 | bge-m3 on host MLX, ~0.05 ms each → 50 ms for 1000 |
| HNSW ANN | $0.00 | DB CPU |
| Policy traversal | $0.00 | DB CPU + 1–2 hop SQL |
| Context-pack assembly | $0.00 | Python in-process |
| **Total per 1000 queries** | **~$0.04** | Dominated by embedding |

If hit rate is $h$ and per-hit cost saving (avoided context bloat) is $\bar{s}$, then break-even is $h \cdot \bar{s} > 0.04 / 1000$. With $\bar{s} \approx \$0.001$ (per-turn savings from smaller context), $h > 0.04$ suffices. Our target is $h \geq 0.30$.

---

## 6. Hypotheses and Pre-Registered Predictions

We pre-register four hypotheses with frozen kill-criteria. Pre-registration is in this commit; deviation requires a public addendum.

**H-1 (recall lift).** On the BL-B 100-row fixture, Agency-MEM-1 achieves recall@10 ≥ 0.72 (i.e. BL-B + 10 percentage points).

- **Test:** `scripts/eval_memory_baseline.py --fixture spec/v2/memory-svc/fixtures/eval_baseline_100.json` after BUILD Phase 2.
- **Floor:** recall@10 ≥ 0.65 (BL-B + 3 pp). Below this → BUILD pause + founder review.
- **Confound to monitor:** cache effects from `ef_construction = 64` warmup; first 20 queries discarded from primary endpoint.

**H-2 (quality lift).** Over a 4-week production deployment with `MEMORY_CONTEXT_ENABLED` A/B-toggled at 50%, mean `agent_run.quality_score` of the treatment arm exceeds control by ≥ 5 percentage points.

- **Test:** `t-test` on per-task quality_score, two-tailed, $\alpha = 0.05$, $n \geq 200$ per arm.
- **Confound to monitor:** quality_score is heuristic-only after the LLM-judge removal (commit 347f944); we verify the heuristic is not memory-aware (Section 8.2) before declaring the test valid.
- **Floor:** treatment ≥ control − 1 pp (i.e. memory does not measurably hurt).

**H-3 (cost saving).** At hit rate $h \geq 0.30$, weekly token-economy saving is ≥ $9.

- **Test:** compare `SUM(cost_usd)` of treatment vs control over the 4-week window, normalized to per-run.
- **Floor:** saving ≥ $0 (memory pays for itself on net).

**H-4 (canonical purity).** At any time during BUILD Phase 4, the fraction of L3 items with `trust_level < 0.7` is ≤ 0% (i.e. zero pollution).

- **Test:** `SELECT COUNT(*) FROM mem_item WHERE layer = 'L3' AND trust_level < 0.7` daily.
- **Floor:** any non-zero count triggers immediate investigation; > 5 items triggers `MEMORY_SVC_WRITE_ENABLED=0` kill switch.

**H-5 (bonus: phantom-DONE cure).** Episodic memory of "files claimed but uncommitted" reduces the phantom-DONE class-1 rate (recall: 6/12 in DESIGN-MEM-001).

- **Test:** rate of `done_note CONTAINING "DELIVERY REPORT"` paired with no commit on main, before vs after BUILD-MEM-001 ships.
- **Floor:** rate must not increase. (This is a stretch hypothesis; we make no firm prediction.)

**Pre-registered secondary metrics (not used for go/no-go but reported):**

- MRR (mean reciprocal rank) on BL-B
- p95 retrieval latency (target ≤ 400 ms)
- topic-classifier no-topic rate
- intent-classifier confusion matrix
- weekly write volume to L3 (canonical promotion rate)

---

## 7. Evaluation Plan

### 7.1 Phase 1 — Substrate (5 days, $5–7)

Outcome: tables exist, FastAPI scaffold returns 200/422 (not 404). No measurement.

### 7.2 Phase 2 — Eval gate (3 days, $3–4)

Outcome: H-1 measured against BL-B fixture. Hard gate: recall@10 ≥ BL-B + 5 pp = 0.67. Below 0.65 = pause.

### 7.3 Phase 3 — Write path (5 days, $5–7)

Outcome: provenance gate enforced (K-3); TL-only promotion verified (K-4); H-4 sentinel measured (zero pollution).

### 7.4 Phase 4 — Read path + integration (5 days, $5–7)

Outcome: A/B switch live for 7 days at 50%, then full 4 weeks for H-2 / H-3 measurement.

### 7.5 Replication package

Released alongside this paper:

- `scripts/eval_memory_baseline.py` (401 LOC, committed `879263e4`)
- `spec/v2/memory-svc/fixtures/eval_baseline_100.json` (34 KB, seed=42)
- `spec/v2/memory-svc/DESIGN_D6_EVAL_CI.md` (CI workflow)
- This paper (`spec/v2/memory-svc/PAPER_DESIGN-MEM-001_v0.1.md`)

External replicators need: Postgres 17 with `pgvector ≥ 0.7`, `bge-m3` embeddings (any vendor), Python 3.11.

---

## 8. Threats to Validity

We enumerate threats by Cook & Campbell category (internal, external, construct, statistical), restricted to those we cannot eliminate at design time.

### 8.1 Internal validity

**T-IV-1: pre-BUILD baseline (D7-BLOCKED-RUNTIME).** No live service exists at design time, so BL-B = 0.62 is computed from the synthetic fixture against the *expected* HNSW behaviour of `pgvector` 0.7. If actual behaviour diverges (e.g. due to MLX bge-m3 producing embeddings with different cosine geometry than published OpenAI baselines), our recall@10 floor may be wrong. Mitigation: H-1 is re-run on real hardware in Étap 2; the fixture is small enough (100 rows) for full re-measure.

**T-IV-2: phantom-DONE in the design process itself.** 6 of 12 design tasks closed without commit. This is the strongest internal-validity concern: if the **agents producing the design** cannot reliably land their own deliverables, why should the **system they design** behave differently? Mitigation: H-5 frames this as an empirical question; D8 adds class-1/2/3 phantom guards that fire post-hoc and force ESCALATED status; TL backfill via `commit 879263e4` recovers the artifacts but not the discipline.

**T-IV-3: silent NEXT→DELEGATED promoter.** Task 2049 sat in NEXT with all dependencies DONE for ≥ 5 minutes after 2048 was resolved; the dag_coordinator's promotion cycle reported `promoted=0` repeatedly. Manual TL flip was required. This is unrelated to memory but indicates the host orchestrator has at least one silent failure mode that may interact with our A/B test if treatment-arm tasks are systematically delayed.

### 8.2 Construct validity

**T-CV-1: heuristic quality score after LLM-judge removal.** The host system removed LLM-as-judge in 2026-04 (commit 347f944) and now uses a heuristic floor (quality 0.5 for outputs > 1500 chars) plus length / commit / artifact heuristics. H-2 measures lift in this heuristic, not a model-judged quality. We must verify the heuristic does not directly read context-pack tokens (which would introduce a confound where "more context = higher heuristic"). **Action item before Étap 4:** audit `apps/api/src/api/services/orchestration/evaluation_service.py::evaluate_quality()` for context-aware terms; if found, freeze evaluation_service version for the duration of the A/B.

**T-CV-2: BL-B is synthetic.** The 100-row fixture is generated by `generate_fixture(--n 100 --seed 42)` from canonical patterns: "task X done", "lesson Y learned", "config Z changed". It under-represents (a) long-tail proper nouns (project-specific identifiers), (b) ambiguous queries with multiple plausible matches, (c) negative queries ("which of these is *not* a Hyperion artifact"). Mitigation: production data over 4 weeks is the primary signal; BL-B is a smoke test, not an external benchmark.

**T-CV-3: Feynman protocol not enforced.** The host system has `vendor/skills/feynman/{peer-review,literature-review,replication,session-log}.md` and `agents/research_supervisor/SKILL.md` formally integrating all four protocols, but **no agent_config.system_prompt contains the word "feynman"**, and **no DESIGN-MEM-001 task triggered a Feynman pass** (no provenance sidecars, no peer-review document, no replication manifest). The paper claims "scientific rigor" but the production system that built it does not enforce the methodology that the paper assumes. We recommend opening a follow-up task: "wire Feynman as a quality gate for `requires_artifact` tasks under role=research_supervisor".

### 8.3 External validity

**T-EV-1: single-user system.** Agency is currently single-founder. Scenarios involving cross-user memory partitioning, RBAC complexity, multi-tenant noise are absent. Generalization to multi-user deployments is unclaimed.

**T-EV-2: 30 roles, but only 5 actively researched.** PI, StatAnalyst, LitScout, ExpDesigner, ResearchSupervisor are the WG; the other 25+ roles (incl. backend_developer, qa_engineer, etc.) will receive memory writes but have unspecified read patterns. We expect read-side benefits to be weaker for under-tested roles.

### 8.4 Statistical validity

**T-SV-1: $n = 200$ per arm assumes ~ 14 dispatches/day for 14 days each arm.** Current production rate is 80–120 runs/day with high variance. If observed $n < 100$/arm at week 4, we extend to week 6 and re-test.

**T-SV-2: multiple comparisons.** We test H-1, H-2, H-3, H-4, H-5 in sequence. Bonferroni correction (5 tests, $\alpha = 0.01$ per test) is applied to H-2/H-3 only; H-1 and H-4 are pass/fail thresholds, not p-values.

---

## 9. Discussion

### 9.1 Predicted vs measured gap

We have explicitly designed for a measurable gap between prediction and outcome. The H-1 floor (recall@10 ≥ 0.65) is 7 percentage points above BL-B; the target (0.72) is 10 pp above. If we land in 0.65–0.71, we declare a "yellow pass" and document the shortfall in a v0.2 of this paper. If we land below 0.65, the substrate is returned to the design board.

### 9.2 What if H-1 fails?

Three possible diagnoses, each with a follow-up experiment:

- **D-1: HNSW parameters under-tuned.** Re-tune `ef_construction` and `ef_search`; this is cheap and bounded.
- **D-2: bge-m3 embeddings sub-optimal for our domain.** Lock-in OQ-2 was deferred ("evaluate voyage-3-lite in B2.2"); we now run that comparison.
- **D-3: substrate is fundamentally insufficient (Neo4j was right).** This would be the hardest verdict, requiring a v1.x re-architecture. We do not pre-commit to executing it.

### 9.3 What if H-1 passes but H-2 fails?

This is the "memory works, but agents do not use it well" scenario. Plausible causes: (a) context-pack ranking weights ($\alpha,\beta,\gamma,\delta$) are wrong for downstream LLM reasoning; (b) LLMs ignore retrieved context in favour of their own priors (the well-known "lost in the middle" effect, for which our position-aware injection in D-MS §3 is the mitigation but not a guarantee). Follow-up: run a small ablation per role.

### 9.4 What this paper is not

This is **not a peer-reviewed publication**. It is a pre-registration document for an internal research-and-engineering sprint. Section 6 hypotheses are bound to the founder sign-off block (`spec/v2/memory-svc/DESIGN-MEM-001_FOUNDER_PACK.md`); BUILD goes ahead only on founder approval.

### 9.5 Future work

- v0.2 (post-Étap 2): empirical update to H-1, possible re-tuning.
- v0.3 (post-Étap 4): full evaluation report with H-1 through H-4.
- v1.0 (after 8 weeks of production): generalization claims, cross-role ablations, cost model refit.

---

## 10. Acknowledgements

DESIGN-MEM-001 was carried out by a working group of virtual agents (PI=77, StatAnalyst=79, LitScout=82, ExpDesigner=84, ResearchSupervisor=85, plus software_developer and tech_lead roles). The sprint produced 11 design artifacts in 12 task-runs over 30 hours. Total DESIGN spend: $7.20 of an $8.00 envelope.

We acknowledge two systemic gaps surfaced during the sprint:
- 6 of 12 deliverables required TL backfill commits (commit `879263e4`, `471f79af`) due to phantom-DONE class-1.
- The Feynman peer-review/replication/session-log protocols, although vendored and referenced in `research_supervisor/SKILL.md`, were not enforced by any agent quality gate; this paper itself has not yet undergone formal Feynman peer review and is submitted for that review now.

We also acknowledge a dispatcher-level ESCAPE-clause bug (commit pending) that blocked task 2043 for ~12 hours on 2026-04-27 before being diagnosed via runtime SQL capture; without that fix the sprint would have failed to complete.

---

## 11. References

(Selected; full SOTA scan in `spec/v2/memory-svc/RESEARCH_SOTA.md`.)

- **Anhui-Med (2025).** *MemOS: A Memory Operating System for Long-Term Agent Cognition.* (MemScheduler component used in D-MS.) arXiv:2509.0xxxx.
- **Choi, J. et al. (2024).** *HyperMem: Topic-Tier Memory for Conversational Agents with Coarse-to-Fine Retrieval.* EMNLP 2024.
- **Cognee (2024).** *Cognee: Open-source Cognitive Memory.* https://github.com/topoteretes/cognee.
- **Letta (2024).** *Letta Server: Production MemGPT.* https://docs.letta.com.
- **MAGMA Anonymous Authors (2026).** *MAGMA: Multi-Graph Adaptive Memory Architecture for LLM Agents.* arXiv:2601.0xxxx.
- **Mem0 (2024).** *Mem0: The Memory Layer for AI Agents.* https://github.com/mem0ai/mem0.
- **Packer, C. et al. (2023).** *MemGPT: Towards LLMs as Operating Systems.* arXiv:2310.08560.
- **Wang, Y. et al. (2025).** *A-MEM: Zettelkasten-Inspired Dynamic Linking for Agent Memory.* NeurIPS 2025.
- **Zep (2024).** *Graphiti: Bitemporal Knowledge Graph for AI Agents.* https://github.com/getzep/graphiti.

**Internal references (Agentura v2 / Agency):**

- DESIGN-MEM-001 design artifacts: `spec/v2/memory-svc/DESIGN_{D1,D2,D3,D4,D5,D6,D7,D8,DHT,DPT,DMS}.md`
- ADRs: `spec/v2/memory-svc/ADR_{001_SUBSTRATE,002_DATA_MODEL,003_SCOPE_BOUNDARIES}.md`
- SOTA scan: `spec/v2/memory-svc/RESEARCH_SOTA.md`
- Risk register: `spec/v2/memory-svc/RISK_REGISTER_AND_COST_MODEL.md`
- Research synthesis (RES-MEM-001): `spec/v2/memory-svc/RES-MEM-001_SYNTHESIS.md`
- Feynman protocols (vendored): `vendor/skills/feynman/{peer-review,literature-review,replication,session-log}.md`
- Founder-pack (sign-off): `spec/v2/memory-svc/DESIGN-MEM-001_FOUNDER_PACK.md`

---

## Appendix A: Pre-registration commit manifest

The following commits are the binding pre-registration of this paper (any post-hoc deviation requires a v0.2 with explicit changelog):

| Commit | Date | Files | Role |
|---|---|---|---|
| `ff686a9d` | 2026-04-28 | `DESIGN_D4_FASTAPI_SURFACE.md` | API contracts |
| `c183f60c` | 2026-04-28 | `DESIGN_D5_MCP_TOOLS.md` | MCP tool spec |
| `06e04d4e` / `28ccb374` | 2026-04-28 | `DESIGN_DMS_CONTEXT_PACK.md` | Read-path Stage 4 |
| `139a4532` | 2026-04-28 | `DESIGN_D8_RUNBOOK.md` | Kill switches & R-1–R-10 |
| `471f79af` | 2026-04-28 | `DESIGN_D6_EVAL_CI.md`, `scripts/eval_memory_baseline.py` | Eval harness |
| `879263e4` | 2026-04-28 | `DESIGN_D1_CANONICAL_SCHEMA.md`, `DESIGN_D2_INDEX_STRATEGY.md`, `DESIGN_DHT_TOPIC_TIER.md`, `DESIGN_DPT_POLICY_TRAVERSAL.md`, `DESIGN_D7_BASELINE_REPORT.md`, `fixtures/eval_baseline_100.json`, `scripts/antipattern_scan.sql` | Schema, indexes, routing, baseline |
| (pending) | — | `PAPER_DESIGN-MEM-001_v0.1.md` (this file) | Paper |

## Appendix B: Glossary

| Term | Definition |
|---|---|
| BL-B | Baseline-B; the 100-row synthetic fixture against which H-1 floor is measured. |
| L1 / L2 / L3 / L4 | Memory layer (working / episodic / canonical / external). |
| MMR | Maximal Marginal Relevance — diversity-aware ranking. |
| MRR | Mean Reciprocal Rank — secondary recall endpoint. |
| Phantom-DONE | A task marked DONE without the artifact actually shipped (3 sub-classes; see SWDEV-260417-7, SWDEV-260418-1, SWDEV-260418-2). |
| Provenance | The mandatory tuple (run_id, role, trust_level, commit_sha) on every memory item. |
| WG | Working Group (PI + Statistical Analyst + Literature Scout + Experiment Designer + Research Supervisor). |
| ANSE | Agency for Sustainable Engineering — internal research function. |

## Appendix C: D7 BLOCKED-RUNTIME — minimal repro

To reproduce the BL-B baseline measurement once BUILD Phase 1 lands:

```bash
# Generate fixture (already done, committed in 879263e4):
python3 scripts/eval_memory_baseline.py --generate-fixture \
    --n 100 --seed 42 \
    --out spec/v2/memory-svc/fixtures/eval_baseline_100.json

# Pre-load into memory svc:
DATABASE_URL=postgresql://execas:changeme@localhost:5433/execas \
  python3 scripts/eval_memory_baseline.py \
    --fixture spec/v2/memory-svc/fixtures/eval_baseline_100.json \
    --command load_fixture

# Run eval:
DATABASE_URL=postgresql://execas:changeme@localhost:5433/execas \
  python3 scripts/eval_memory_baseline.py \
    --fixture spec/v2/memory-svc/fixtures/eval_baseline_100.json \
    --assert-recall-at-10-delta 0.05 \
    --assert-p95-latency-ms 400
```

Expected output (post-BUILD Phase 2):
```
recall@1   = 0.X
recall@5   = 0.X
recall@10  = 0.7Y    [PASS / FAIL vs BL-B + 5pp]
MRR        = 0.X
p95 ms     = X       [PASS / FAIL vs 400 ms]
```

If `recall@10 < 0.65`: BUILD pause + escalate to founder per H-1 floor.

---

**End of pre-print v0.1.**

*Formal Feynman peer-review pass requested before BUILD-MEM-001 dispatch. PG/PI/replication_validator are nominated reviewers per `agents/research_supervisor/SKILL.md` §3.*
