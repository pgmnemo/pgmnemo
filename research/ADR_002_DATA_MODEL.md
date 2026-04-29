# ADR-002: Memory Service Data Model

**Status:** PROPOSED  
**Date:** 2026-04-27  
**Depends on:** ADR-001 (Substrate: PostgreSQL + pgvector + Apache AGE)  
**Research inputs:** R1 (RESEARCH_SOTA), R2 (RESEARCH_CURRENT_STACK_LIMITS), R3 (ADR-001)  
**Decision owners:** Founder (final), PI (recommendation)

---

## 1. Summary

This ADR projects the five memory layers (ТЗ §6) onto concrete PostgreSQL tables,
pgvector indexes, and AGE graph node/edge types within the substrate chosen by ADR-001.
It defines schemas for all §9 entities, the §8 state machine, §11 metadata fields,
§10 relation types, and federation boundaries with existing Agentura tables.

---

## 2. Design Principles

| # | Principle | Rationale |
|---|-----------|-----------|
| P1 | Single ACID surface | All memory writes in one PG transaction — prevents phantom-consistency (ADR-001 §Decision) |
| P2 | Federation over duplication | Existing tables (`tasks`, `agent_run`, `projects`, `user_goals`) are referenced by FK, not copied |
| P3 | Embeddings co-located | All vector columns use `pgvector vector(1024)` with HNSW indexes — no separate vector DB |
| P4 | Graph as overlay | AGE graph (`memory_graph`) references relational PKs; authoritative data lives in tables |
| P5 | Bitemporal by default | Every mutable entity carries `valid_from`/`valid_until` (real-world) + `created_at`/`superseded_at` (system) |
| P6 | TTL-driven eviction | Working memory (L1) has hard TTL; other layers use soft deprecation via state machine |

---

## 3. Memory Layer → Table Mapping

| Layer | Primary table(s) | Graph presence | TTL |
|-------|-----------------|----------------|-----|
| **L1 Working** | `mem_working_item` | No (ephemeral) | Hard: `expires_at` (default 4h from run start) |
| **L2 Episodic** | `mem_episode` | Yes: `Episode` node + `OCCURRED_IN` edges | Soft: state → `archived` after 90d inactivity |
| **L3 Semantic** | `mem_claim`, `mem_entity` | Yes: `Entity`/`Claim` nodes + typed edges | Soft: state machine driven |
| **L4 Procedural** | `mem_policy` | Yes: `Policy` node + `APPLIES_TO` edges | Soft: `deprecated` when superseded |
| **L5 Meta-cognitive** | `mem_decision`, `mem_evidence` | Yes: `Decision`/`Evidence` nodes + `SUPPORTS`/`CONTRADICTS` | Soft: `archived` when resolved |

---

## 4. State Machine (§8)

### 4.1 Enum Definition

```sql
CREATE TYPE mem_item_state AS ENUM (
  'draft',        -- created, not yet reviewed
  'candidate',    -- proposed for validation
  'validated',    -- passes quality gate
  'canonical',    -- authoritative, actively retrieved
  'deprecated',   -- superseded or stale, excluded from retrieval
  'superseded',   -- replaced by a newer item (FK: superseded_by)
  'archived',     -- cold storage, queryable but not injected
  'rejected',     -- failed quality gate, never promoted
  'conflicted'    -- contradicts canonical item, needs resolution
);
```

### 4.2 Allowed Transitions

```
draft       → candidate | rejected
candidate   → validated | rejected | conflicted
validated   → canonical | rejected
canonical   → deprecated | superseded | archived | conflicted
deprecated  → archived | canonical (re-promotion)
superseded  → archived
conflicted  → canonical | rejected | archived
archived    → (terminal — no outbound transitions)
rejected    → (terminal — no outbound transitions)
```

### 4.3 Transition Table (enforced by CHECK or trigger)

```sql
CREATE TABLE mem_state_transition (
  from_state  mem_item_state NOT NULL,
  to_state    mem_item_state NOT NULL,
  PRIMARY KEY (from_state, to_state)
);

-- Seed with allowed pairs from §4.2
INSERT INTO mem_state_transition VALUES
  ('draft','candidate'), ('draft','rejected'),
  ('candidate','validated'), ('candidate','rejected'), ('candidate','conflicted'),
  ('validated','canonical'), ('validated','rejected'),
  ('canonical','deprecated'), ('canonical','superseded'), ('canonical','archived'), ('canonical','conflicted'),
  ('deprecated','archived'), ('deprecated','canonical'),
  ('superseded','archived'),
  ('conflicted','canonical'), ('conflicted','rejected'), ('conflicted','archived');
```

---

## 5. Core Schema: `mem_item` (base table)

All memory items share a common base tracked via single-table inheritance (discriminator: `item_type`).

```sql
CREATE TABLE mem_item (
  id              BIGSERIAL PRIMARY KEY,
  item_type       TEXT NOT NULL,  -- discriminator: 'claim','entity','episode','decision','policy','evidence','working'
  
  -- §8 State machine
  state           mem_item_state NOT NULL DEFAULT 'draft',
  state_changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  -- §11 Metadata
  project_id      INT REFERENCES projects(id),
  agent_config_id INT REFERENCES agent_config(id),
  source_run_id   INT REFERENCES agent_run(id),
  source_task_id  INT REFERENCES tasks(id),
  created_by      TEXT NOT NULL,          -- agent role or 'user' or 'system'
  
  -- Bitemporality (P5)
  valid_from      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  valid_until     TIMESTAMPTZ,            -- NULL = currently valid
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  superseded_at   TIMESTAMPTZ,            -- NULL = not superseded
  superseded_by   BIGINT REFERENCES mem_item(id),
  
  -- Content
  content_text    TEXT NOT NULL,
  content_summary TEXT,                   -- ≤200 chars, Haiku-generated
  
  -- Vector embedding (P3)
  embedding       vector(1024),           -- voyage-3-lite or bge-m3
  
  -- Quality + trust
  quality_score   REAL,                   -- [0.0, 1.0]
  trust_level     REAL DEFAULT 0.5,       -- [0.0, 1.0] — rises with validation evidence
  access_count    INT DEFAULT 0,          -- retrieval counter for LRU/LFU
  last_accessed   TIMESTAMPTZ,
  
  -- Labelling
  labels          JSONB DEFAULT '[]'::jsonb,  -- free-form tags
  metadata        JSONB DEFAULT '{}'::jsonb,  -- extensible §11 metadata
  
  -- TTL (L1 only, NULL for other layers)
  expires_at      TIMESTAMPTZ
);

-- Discriminator index
CREATE INDEX ix_mem_item_type ON mem_item (item_type);

-- State + project for retrieval queries
CREATE INDEX ix_mem_item_state_project ON mem_item (state, project_id) WHERE state IN ('canonical','validated');

-- Vector HNSW
CREATE INDEX ix_mem_item_embedding ON mem_item USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 128);

-- TTL eviction (L1 working memory)
CREATE INDEX ix_mem_item_expires ON mem_item (expires_at) WHERE expires_at IS NOT NULL;

-- Bitemporality range scans
CREATE INDEX ix_mem_item_valid_range ON mem_item (valid_from, valid_until);
```

---

## 6. Layer-Specific Tables

### 6.1 L1 — Working Memory: `mem_working_item`

Ephemeral per-run context fragments (tool outputs, partial results, compaction summaries).

```sql
CREATE TABLE mem_working_item (
  id              BIGINT PRIMARY KEY REFERENCES mem_item(id) ON DELETE CASCADE,
  run_id          INT NOT NULL REFERENCES agent_run(id),
  turn_number     INT,
  tool_name       TEXT,
  fragment_type   TEXT NOT NULL,  -- 'tool_output','compaction_summary','partial_result','checkpoint'
  byte_size       INT,
  
  -- No embedding (ephemeral, not retrieved cross-run)
  -- TTL enforced via mem_item.expires_at (default: run_start + 4h)
  CONSTRAINT chk_working_has_ttl CHECK (TRUE)  -- enforced at app level via mem_item.expires_at
);

CREATE INDEX ix_working_run ON mem_working_item (run_id, turn_number);
```

**Partitioning:** Range on `mem_item.created_at` (monthly). Working items auto-drop via TTL + partition detach.

**TTL policy:** `expires_at = run.started_at + INTERVAL '4 hours'`. Eviction job runs every 15 min:
```sql
DELETE FROM mem_item WHERE item_type = 'working' AND expires_at < NOW();
```

### 6.2 L2 — Episodic Memory: `mem_episode`

Per-run structured episode summaries with semantic search.

```sql
CREATE TABLE mem_episode (
  id              BIGINT PRIMARY KEY REFERENCES mem_item(id) ON DELETE CASCADE,
  run_id          INT NOT NULL REFERENCES agent_run(id),
  task_id         INT REFERENCES tasks(id),
  dag_id          TEXT,                     -- extracted from task labels
  phase           TEXT,                     -- 'RESEARCH','IMPLEMENT', etc.
  
  -- Episode structure
  outcome         TEXT NOT NULL,            -- 'completed','failed','cancelled','escalated'
  turns_count     INT,
  cost_usd        REAL,
  tools_used      TEXT[],                   -- array of tool names
  files_touched   TEXT[],                   -- array of file paths
  key_decisions   JSONB DEFAULT '[]',       -- [{decision, rationale}]
  errors_encountered JSONB DEFAULT '[]',    -- [{error_class, message}]
  
  -- Temporal anchors
  episode_start   TIMESTAMPTZ NOT NULL,
  episode_end     TIMESTAMPTZ
);

CREATE INDEX ix_episode_run ON mem_episode (run_id);
CREATE INDEX ix_episode_task ON mem_episode (task_id);
CREATE INDEX ix_episode_dag ON mem_episode (dag_id) WHERE dag_id IS NOT NULL;
CREATE INDEX ix_episode_outcome ON mem_episode (outcome, phase);
```

### 6.3 L3 — Semantic Memory: `mem_claim` + `mem_entity`

Distilled knowledge facts and named entities.

```sql
-- Claims: atomic factual statements with provenance
CREATE TABLE mem_claim (
  id              BIGINT PRIMARY KEY REFERENCES mem_item(id) ON DELETE CASCADE,
  claim_type      TEXT NOT NULL,       -- 'fact','decision','constraint','convention','observation'
  confidence      REAL DEFAULT 0.5,    -- [0.0, 1.0]
  domain          TEXT,                -- 'architecture','process','business','technical'
  scope           TEXT,                -- 'global','project','task_family','agent_role'
  
  -- Provenance chain
  evidence_ids    BIGINT[],            -- references to mem_evidence rows
  source_context  TEXT                 -- verbatim excerpt that generated the claim
);

CREATE INDEX ix_claim_domain ON mem_claim (domain, claim_type);
CREATE INDEX ix_claim_confidence ON mem_claim (confidence DESC) WHERE confidence >= 0.7;

-- Entities: named things (files, services, people, concepts)
CREATE TABLE mem_entity (
  id              BIGINT PRIMARY KEY REFERENCES mem_item(id) ON DELETE CASCADE,
  entity_type     TEXT NOT NULL,       -- 'file','service','person','concept','tool','model','table','endpoint'
  canonical_name  TEXT NOT NULL,       -- normalized identifier
  aliases         TEXT[],              -- alternative names
  description     TEXT,
  
  CONSTRAINT uq_entity_name_project UNIQUE (canonical_name, entity_type)
    -- per-project uniqueness enforced at app level (project_id on mem_item)
);

CREATE INDEX ix_entity_type ON mem_entity (entity_type);
CREATE INDEX ix_entity_name ON mem_entity (canonical_name);
```

### 6.4 L4 — Procedural Memory: `mem_policy`

Skills, tool patterns, agent role playbooks, conventions.

```sql
CREATE TABLE mem_policy (
  id              BIGINT PRIMARY KEY REFERENCES mem_item(id) ON DELETE CASCADE,
  policy_type     TEXT NOT NULL,       -- 'skill','tool_pattern','convention','playbook','guard_rule'
  applies_to_role TEXT[],              -- agent roles this policy applies to (NULL = all)
  applies_to_phase TEXT[],             -- DAG phases (NULL = all)
  
  -- Structured content
  precondition    TEXT,                -- when to apply
  action          TEXT NOT NULL,       -- what to do
  postcondition   TEXT,                -- expected outcome
  anti_pattern    TEXT,                -- what NOT to do
  
  -- Effectiveness tracking
  success_count   INT DEFAULT 0,
  failure_count   INT DEFAULT 0,
  last_applied_at TIMESTAMPTZ
);

CREATE INDEX ix_policy_role ON mem_policy USING gin (applies_to_role);
CREATE INDEX ix_policy_type ON mem_policy (policy_type);
```

### 6.5 L5 — Meta-cognitive Memory: `mem_decision` + `mem_evidence`

Cross-run lessons, error patterns, self-corrections, causal reasoning.

```sql
-- Decisions: architectural, process, or operational choices
CREATE TABLE mem_decision (
  id              BIGINT PRIMARY KEY REFERENCES mem_item(id) ON DELETE CASCADE,
  decision_type   TEXT NOT NULL,       -- 'architectural','process','operational','tactical'
  context         TEXT NOT NULL,       -- situation that triggered the decision
  chosen_option   TEXT NOT NULL,       -- what was decided
  alternatives    JSONB DEFAULT '[]',  -- [{option, reason_rejected}]
  outcome         TEXT,                -- observed result (filled post-hoc)
  outcome_quality REAL                 -- [0.0, 1.0] retrospective assessment
);

CREATE INDEX ix_decision_type ON mem_decision (decision_type);

-- Evidence: observations that support or contradict claims/decisions
CREATE TABLE mem_evidence (
  id              BIGINT PRIMARY KEY REFERENCES mem_item(id) ON DELETE CASCADE,
  evidence_type   TEXT NOT NULL,       -- 'observation','measurement','assertion','error_pattern','benchmark'
  supports_id     BIGINT REFERENCES mem_item(id),   -- claim or decision this supports
  contradicts_id  BIGINT REFERENCES mem_item(id),   -- claim or decision this contradicts
  strength        REAL DEFAULT 0.5,    -- [0.0, 1.0] — weight of this evidence
  
  -- For error_pattern type: link to existing error infrastructure
  error_fingerprint TEXT,              -- from error_events.fingerprint
  occurrence_count  INT DEFAULT 1
);

CREATE INDEX ix_evidence_supports ON mem_evidence (supports_id) WHERE supports_id IS NOT NULL;
CREATE INDEX ix_evidence_contradicts ON mem_evidence (contradicts_id) WHERE contradicts_id IS NOT NULL;
CREATE INDEX ix_evidence_fingerprint ON mem_evidence (error_fingerprint) WHERE error_fingerprint IS NOT NULL;
```

---

## 7. Graph Layer (AGE / Recursive CTE)

### 7.1 Phase 1: Adjacency table (recursive CTE compatible)

```sql
CREATE TABLE mem_edge (
  id              BIGSERIAL PRIMARY KEY,
  source_id       BIGINT NOT NULL REFERENCES mem_item(id) ON DELETE CASCADE,
  target_id       BIGINT NOT NULL REFERENCES mem_item(id) ON DELETE CASCADE,
  relation_type   TEXT NOT NULL,       -- §10 relation types (see §7.3)
  
  -- Bitemporality
  valid_from      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  valid_until     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  -- Edge metadata
  weight          REAL DEFAULT 1.0,    -- edge strength/confidence
  metadata        JSONB DEFAULT '{}'::jsonb,
  
  CONSTRAINT uq_edge UNIQUE (source_id, target_id, relation_type, valid_from)
);

CREATE INDEX ix_edge_source ON mem_edge (source_id, relation_type);
CREATE INDEX ix_edge_target ON mem_edge (target_id, relation_type);
CREATE INDEX ix_edge_type ON mem_edge (relation_type);
CREATE INDEX ix_edge_valid ON mem_edge (valid_from, valid_until);
```

### 7.2 Phase 2: AGE Graph (when traversal depth > 3 required)

```sql
-- Phase 2 only: after AGE extension is installed
LOAD 'age';
SET search_path = ag_catalog, public;
SELECT create_graph('memory_graph');

-- Node labels (map to item_type):
-- :Entity, :Claim, :Episode, :Decision, :Policy, :Evidence

-- Edge labels (map to relation_type):
-- :MENTIONS, :CAUSED_BY, :SUPPORTS, :CONTRADICTS, :SUPERSEDES,
-- :OCCURRED_IN, :APPLIES_TO, :DERIVED_FROM, :DEPENDS_ON, :PART_OF

-- Example Cypher (via AGE):
-- MATCH (e:Episode)-[:CAUSED_BY]->(err:Evidence {evidence_type:'error_pattern'})
--       -[:SUPPORTS]->(lesson:Decision)
-- WHERE e.run_id = $run_id
-- RETURN lesson.content_text, err.occurrence_count
```

### 7.3 Relation Types (§10)

| Relation | Source type(s) | Target type(s) | Semantics |
|----------|---------------|----------------|-----------|
| `MENTIONS` | Episode | Entity | Entity was referenced in episode |
| `CAUSED_BY` | Episode, Evidence | Episode, Evidence, Entity | Causal link |
| `SUPPORTS` | Evidence | Claim, Decision | Evidence validates target |
| `CONTRADICTS` | Evidence, Claim | Claim, Decision | Conflict / invalidation |
| `SUPERSEDES` | Claim, Policy | Claim, Policy | Newer replaces older |
| `OCCURRED_IN` | Episode | (external: agent_run) | Temporal anchor |
| `APPLIES_TO` | Policy | Entity, (external: tasks) | Scope of policy |
| `DERIVED_FROM` | Claim, Decision | Episode, Evidence | Provenance chain |
| `DEPENDS_ON` | Decision | Decision, Claim | Prerequisite relationship |
| `PART_OF` | Entity, Claim | Entity | Compositional hierarchy |
| `SIMILAR_TO` | any | any | Embedding-space neighbor (weight = cosine sim) |
| `ADDRESSES` | Policy, Decision | Evidence | Remediation link (lesson → error) |
| `PRODUCED_BY` | Entity (artifact) | Episode | Artifact creation provenance |

---

## 8. §9 Entity Mapping: Memory Service vs Federated

### 8.1 Entities owned by Memory Service (new tables)

| §9 Entity | Table | item_type | Notes |
|-----------|-------|-----------|-------|
| MemoryItem | `mem_item` | (all) | Base table — all memory items are MemoryItems |
| Entity | `mem_entity` | `entity` | Named things extracted from episodes |
| Relation | `mem_edge` | — | Edges between items (not itself a mem_item) |
| Episode | `mem_episode` | `episode` | Structured run summaries |
| Decision | `mem_decision` | `decision` | Choices with alternatives |
| Claim | `mem_claim` | `claim` | Atomic factual statements |
| Evidence | `mem_evidence` | `evidence` | Observations supporting/contradicting |
| Policy | `mem_policy` | `policy` | Skills, conventions, playbooks |

### 8.2 Entities federated from existing Agentura tables (referenced by FK)

| §9 Entity | Existing table | FK from mem_item | Notes |
|-----------|---------------|------------------|-------|
| Agent | `agent_config` | `agent_config_id` | Agent identity + model config |
| Team | `delegation_assignees` | via `agent_config.assignee_id` | Role roster |
| Goal | `user_goals` | — (via task → goal_task_link) | Top-level objectives |
| Subgoal | `user_goals` (parent_id) | — (via task → goal_task_link) | Nested objectives |
| Task | `tasks` | `source_task_id` | Work units |
| Event | `error_events` | `mem_evidence.error_fingerprint` | System events |
| Artifact | files on disk / `agent_run.result_summary` | `mem_entity.entity_type='artifact'` | Produced outputs |
| ToolRun | `agent_run_turn` | `mem_working_item.run_id` + `turn_number` | Individual tool executions |
| User | (single-tenant, implicit) | `mem_item.created_by='user'` | Founder |
| Approval | `tasks.labels` / workflow state | — | GTD status transitions |

### 8.3 Federation rules

1. Memory service **never duplicates** federated entity data — only stores FK references.
2. Joins across federation boundary use standard PG foreign keys (same DB instance).
3. If a federated entity is deleted, `ON DELETE SET NULL` on FK columns — memory item retains content but loses link.
4. Graph edges to federated entities use `metadata.external_table` + `metadata.external_id` in `mem_edge.metadata` JSONB.

---

## 9. §11 Metadata Schema

Every `mem_item` carries structured metadata in the `metadata` JSONB column:

```jsonc
{
  // Provenance (§11.1)
  "source_type": "agent_run|user_input|system_extraction|distillation",
  "extraction_model": "claude-haiku-4-5|claude-sonnet-4-6",
  "extraction_prompt_version": "v1.2",
  
  // Temporal (§11.2) — also in dedicated columns for indexing
  "observed_at": "2026-04-27T14:30:00Z",   // when the fact was true in the real world
  "reported_at": "2026-04-27T14:35:00Z",   // when the system learned it
  
  // Scope (§11.3)
  "scope_project_ids": [9],
  "scope_agent_roles": ["tech_lead", "implementer"],
  "scope_task_families": ["SWDEV", "BIZ"],
  "scope_phases": ["IMPLEMENT", "CODE_REVIEW"],
  
  // Lineage (§11.4)
  "parent_item_ids": [42, 55],             // items this was derived from
  "child_item_ids": [101],                 // items derived from this
  "consolidation_round": 3,               // which distillation pass created this
  
  // Retrieval hints (§11.5)
  "retrieval_weight": 1.0,                // boost/demote in retrieval ranking
  "inject_as": "system_context|few_shot|tool_hint",
  "max_inject_chars": 500
}
```

---

## 10. Indexes Strategy

### 10.1 Primary retrieval indexes

| Index | Type | Purpose | Layer |
|-------|------|---------|-------|
| `ix_mem_item_embedding` | HNSW (m=16, ef=128) | Semantic similarity search | L2–L5 |
| `ix_mem_item_state_project` | btree composite | Filter canonical/validated items per project | All |
| `ix_mem_item_type` | btree | Discriminator filter | All |
| `ix_mem_item_expires` | btree partial | TTL eviction scan | L1 |
| `ix_mem_item_valid_range` | btree composite | Bitemporal range queries | All |
| `ix_edge_source` | btree composite | Graph traversal from node | Graph |
| `ix_edge_target` | btree composite | Reverse graph traversal | Graph |

### 10.2 GIN indexes for JSONB

```sql
CREATE INDEX ix_mem_item_labels ON mem_item USING gin (labels jsonb_path_ops);
CREATE INDEX ix_mem_item_metadata ON mem_item USING gin (metadata jsonb_path_ops);
```

### 10.3 Partial indexes (hot-path optimization)

```sql
-- Only canonical+validated items are retrieved — skip 80%+ of rows
CREATE INDEX ix_mem_item_active_embedding ON mem_item USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 128)
  WHERE state IN ('canonical', 'validated') AND embedding IS NOT NULL;

-- Episodes for a specific DAG (common query pattern)
CREATE INDEX ix_episode_dag_active ON mem_episode (dag_id)
  WHERE dag_id IS NOT NULL;
```

---

## 11. Partitioning Strategy

### 11.1 `mem_item` — Range partition on `created_at` (monthly)

```sql
CREATE TABLE mem_item (
  ...
) PARTITION BY RANGE (created_at);

CREATE TABLE mem_item_2026_04 PARTITION OF mem_item
  FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE mem_item_2026_05 PARTITION OF mem_item
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
-- Auto-create future partitions via pg_partman or cron job
```

**Rationale:** Working memory (L1) items are short-lived — monthly partitions allow efficient `DROP` of old L1-heavy partitions. Retrieval queries filter `state IN ('canonical','validated')` which skips expired partitions automatically.

### 11.2 `mem_edge` — No partitioning (MVP)

At projected 100K items × avg 3 edges = 300K edges — well within single-table performance.
Re-evaluate at 1M edges.

### 11.3 `mem_working_item` — Inherits mem_item partition

Working items inherit the `mem_item` partition (same monthly range). TTL eviction job deletes expired rows; partition detach used for bulk cleanup of months where all items expired.

---

## 12. Connectivity to Existing Tables

### 12.1 Views for backward compatibility

```sql
-- Bridge: expose mem_claims as project_context_items format for existing context_service
CREATE VIEW v_mem_as_context_items AS
SELECT
  mi.id,
  mi.project_id,
  'memory_claim' AS context_type,
  mc.claim_type AS sub_type,
  mi.content_text AS summary,
  mi.embedding AS embedding_vector,
  mi.quality_score AS quality,
  mi.state,
  mi.created_at
FROM mem_item mi
JOIN mem_claim mc ON mc.id = mi.id
WHERE mi.state IN ('canonical', 'validated');

-- Bridge: expose mem_episodes as agent_reflection format
CREATE VIEW v_mem_as_reflections AS
SELECT
  mi.id,
  me.run_id AS agent_run_id,
  mi.content_text AS reflection_text,
  mi.quality_score AS quality_score,
  mi.embedding AS embedding_vector,
  mi.created_at
FROM mem_item mi
JOIN mem_episode me ON me.id = mi.id
WHERE mi.state IN ('canonical', 'validated', 'archived');
```

### 12.2 Foreign key map to existing tables

```
mem_item.project_id       → projects.id
mem_item.agent_config_id  → agent_config.id
mem_item.source_run_id    → agent_run.id
mem_item.source_task_id   → tasks.id
mem_episode.run_id        → agent_run.id
mem_episode.task_id       → tasks.id
```

---

## 13. Migration Implications

### 13.1 New tables (no existing data affected)

| Migration | Tables created | Estimated effort |
|-----------|---------------|-----------------|
| `v2_110_mem_item_base` | `mem_item` (partitioned), `mem_state_transition` | 1 migration |
| `v2_111_mem_layers` | `mem_working_item`, `mem_episode`, `mem_claim`, `mem_entity`, `mem_policy`, `mem_decision`, `mem_evidence` | 1 migration |
| `v2_112_mem_graph` | `mem_edge` | 1 migration |
| `v2_113_mem_views` | `v_mem_as_context_items`, `v_mem_as_reflections` | 1 migration |

### 13.2 Data backfill (one-time ETL from existing tables)

| Source | Target | Strategy |
|--------|--------|----------|
| `agent_reflection` (1,127 active) | `mem_episode` | Batch: create mem_item + mem_episode per reflection; re-embed with 1024-dim model |
| `agent_lesson` (86 active) | `mem_decision` or `mem_policy` | Batch: classify each lesson as decision/policy; create with state=`validated` |
| `project_context_items` (270 active) | `mem_claim` | Batch: map `context_type` → `claim_type`; preserve embeddings if dim=1024 |
| `error_events` (2,244) | `mem_evidence` (evidence_type='error_pattern') | Batch: group by fingerprint; one evidence item per unique fingerprint |

### 13.3 Coexistence period

During migration, both old tables and new `mem_*` tables exist. `context_service.py` reads from both via views. Cutover: when all retrieval paths use `mem_*` tables exclusively, old tables become read-only archives.

---

## 14. Embedding Strategy

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Dimension | 1024 | bge-m3 produces 1024-d vectors; ~~voyage-3-lite (1024)~~ struck — never deployed (ADR-002-DECISION-2026-04-29) |
| Distance metric | Cosine | Consistent with existing 11 HNSW indexes |
| HNSW params | m=16, ef_construction=128, ef_search=64 | Optimized for <100K rows per ADR-001 §scale |
| Embedding model | ~~`voyage-3-lite` (primary)~~ `bge-m3` (primary, MLX macOS, port 9200) | DECISION-2026-04-29: bge-small REJECTED (recall@10 0.578 < 0.58 threshold); bge-m3 confirmed sole production model |
| Batch embedding | On insert (synchronous for L3-L5), deferred for L1 (no embedding) | L1 is ephemeral — embedding waste |
| Re-embedding | On content_text change (state transition trigger) | Ensures embedding ↔ content consistency |

> **ADR-002-DECISION-2026-04-29** — Working group reviewed RES-MEM-EMBED-1 (`SPIKE_EMBED_BENCHMARK.md`, 2026-04-29). Decided to **REJECT** switching to bge-small-en-v1.5 (analytical recall@10 estimate 0.578 < 0.58 working-group threshold; empirical run blocked by infra gap in agent container). `bge-m3` + MLX confirmed as the sole production embedding model. `voyage-3-lite` was listed as primary in earlier drafts but has never been deployed — that entry is struck. BL-B anchor 0.62 remains valid (bge-m3 checkpoint unchanged; see `D6_BL_B_VARIANCE.md`).

### 14.1 Measured baseline (2026-04-29)

Source: `spec/v2/memory-svc/SPIKE_EMBED_BENCHMARK.md` (RES-MEM-EMBED-1 / task 2099, 2026-04-29)

**Note:** Live benchmark was blocked by infrastructure gap (torch/numpy/FlagEmbedding absent in agent container; MLX service unreachable at host.docker.internal:9200). Figures below are the bge-m3 BL-B fixture anchor plus analytical estimates derived from MTEB/BEIR literature proxy (ratio method §4.2 of spike doc).

| Metric | bge-m3 (production, 1024-d) | bge-small-en-v1.5 (REJECTED, 384-d) | Notes |
|--------|-----------------------------|------------------------------------|-------|
| recall@10 (BL-B) | **0.620** (fixture anchor, exact) | 0.578 ± 0.025 (analytical est.) | Decision boundary: 0.58 |
| recall@10 95% CI | [0.60, 0.64] | [0.544, 0.624] | n=100 BL-B fixture |
| Storage per 10K docs | 41.0 MB | 15.4 MB | 4B × dim × 10K × 1.3 HNSW overhead |
| Query latency p50 (CPU est.) | ~25 ms (MLX macOS) | ~8 ms (in-process) | Public benchmark proxy |
| Query latency p95 (CPU est.) | ~45 ms | ~15 ms | Public benchmark proxy |
| Ops overhead | MLX LaunchAgent + port 9200 | None (in-process) | +1 failure domain for bge-m3 |
| Model size on disk | 2.27 GB | 133 MB | HuggingFace checkpoint |

**Verdict: REJECT bge-small.** Point estimate (0.578) falls below the 0.58 floor; CI lower bound 0.544 makes this statistically inconclusive at n=100 (59% power for 4 pp effect — §2.2 of spike). Re-open conditions: (a) live empirical run bge-small recall@10 ≥ 0.58 at n=100, or (b) fixture expanded to n ≥ 400 + recall@10 ≥ 0.58.

---

## 15. Retrieval Query Patterns

### 15.1 Semantic search (all layers)

```sql
-- Top-k similar items for a query embedding, scoped to project, active state
SELECT mi.id, mi.content_text, mi.quality_score,
       1 - (mi.embedding <=> $query_embedding) AS similarity
FROM mem_item mi
WHERE mi.state IN ('canonical', 'validated')
  AND mi.project_id = $project_id
  AND mi.item_type = ANY($target_types)
  AND mi.embedding IS NOT NULL
ORDER BY mi.embedding <=> $query_embedding
LIMIT $k;
```

### 15.2 Graph traversal (2-hop example via recursive CTE)

```sql
-- Find all evidence supporting claims related to a given entity
WITH RECURSIVE chain AS (
  -- Start: edges from the entity
  SELECT e.target_id AS node_id, e.relation_type, 1 AS depth
  FROM mem_edge e
  WHERE e.source_id = $entity_id
    AND e.relation_type IN ('MENTIONS', 'DERIVED_FROM')
    AND (e.valid_until IS NULL OR e.valid_until > NOW())
  
  UNION ALL
  
  -- Recurse: one more hop
  SELECT e2.target_id, e2.relation_type, c.depth + 1
  FROM chain c
  JOIN mem_edge e2 ON e2.source_id = c.node_id
  WHERE c.depth < 3
    AND (e2.valid_until IS NULL OR e2.valid_until > NOW())
)
SELECT DISTINCT mi.*
FROM chain c
JOIN mem_item mi ON mi.id = c.node_id
WHERE mi.state IN ('canonical', 'validated');
```

### 15.3 Episodic retrieval (L2 — "what happened last time on this task")

```sql
SELECT mi.content_text, me.outcome, me.turns_count, me.cost_usd,
       me.key_decisions, me.errors_encountered
FROM mem_episode me
JOIN mem_item mi ON mi.id = me.id
WHERE me.task_id = $task_id
  AND mi.state != 'rejected'
ORDER BY me.episode_end DESC
LIMIT 5;
```

---

## 16. Quality Gates for DDL Generation

| Gate | Criterion | Evidence |
|------|-----------|----------|
| G1 | All §9 entities mapped to table or federation FK | §8 table (18 entities covered) |
| G2 | State machine formally defined with enum + transition table | §4 (9 states, 16 transitions) |
| G3 | Every layer has explicit TTL/retention policy | §6.1 (L1 hard TTL), §3 (L2-L5 soft via state) |
| G4 | Graph relation types enumerated with source/target constraints | §7.3 (13 relation types) |
| G5 | Embedding strategy specified (dim, model, HNSW params) | §14 |
| G6 | Migration sequence defined without ambiguity | §13.1 (4 migrations, ordered) |
| G7 | Backward-compatible views for existing context_service | §12.1 (2 views) |
| G8 | Retrieval patterns demonstrable as valid SQL | §15 (3 patterns) |

---

## 17. Open Questions (deferred to implementation)

| # | Question | Impact | Resolution path |
|---|----------|--------|-----------------|
| Q1 | Partition auto-creation strategy (pg_partman vs cron) | Ops | Decide during v2_110 migration implementation |
| Q2 | Embedding dimension migration path if switching to 768-dim model | Index rebuild | Document in ADR-003 (Embedding Strategy) if model changes |
| Q3 | AGE installation timing (Phase 2 trigger: when recursive CTE > 3 hops needed) | Query complexity | Monitor traversal depth in production; trigger at p95 > 100ms |
| Q4 | Backfill batch size and rate limiting | Migration duration | Test with 100-row batch, measure embedding API cost |
| Q5 | Read replica vs connection pool split for memory queries | Latency ceiling | Monitor pg_stat_statements after launch; split if p95 > 200ms |

---

## 18. References

- ADR-001: `spec/v2/memory-svc/ADR_001_SUBSTRATE.md` — substrate selection (PG + pgvector + AGE)
- R1: `spec/v2/memory-svc/RESEARCH_SOTA.md` — 7-system SOTA scan, patterns B1-B3
- R2: `spec/v2/memory-svc/RESEARCH_CURRENT_STACK_LIMITS.md` — 13 gap analysis
- R7: `spec/v2/memory-svc/EVAL_METRICS.md` — evaluation metrics spec
- R8: `spec/v2/memory-svc/EVAL_SCENARIOS.md` — 5 long-horizon test scenarios
- Existing models: `apps/executive-cli/src/executive_cli/models.py`
- Existing migrations: `apps/executive-cli/alembic/versions/v2_001–v2_100`
