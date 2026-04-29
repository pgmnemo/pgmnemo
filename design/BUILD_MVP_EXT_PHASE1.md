# pgmnemo W1 — BUILD_MVP_EXT_PHASE1: 6-Week Implementation Plan (Variant 1: SQL-only PG Extension)

**Document:** `spec/v2/pgmnemo/design/BUILD_MVP_EXT_PHASE1.md`
**Date:** 2026-04-29
**Author:** TL synthesis
**Status:** DRAFT — pending founder sign-off before BUILD begins
**Depends on:** ADR-001 (Substrate), ADR-002 (Data Model), SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md
**Deadline:** 2026-05-03 (plan delivery); BUILD start gated on founder approval

---

## 0. Scope and Variant Definition

**Variant 1 (SQL-only PG Extension)** means: all agent-facing read operations — lesson recall,
concept search, provenance audit — are implemented as PL/pgSQL functions in a `pgmnemo.*` schema,
callable directly via `tasks_db` MCP with zero FastAPI hops on the read path. Write and
distillation remain in the FastAPI microservice (HYBRID architecture, per EXT-3 §5.1).

**What this plan covers:**
- Extension control file and schema structure (`.control` + SQL install scripts)
- Three core tables: `agent_lesson`, `memory_concept`, `provenance_log`
- Two PL/pgSQL retrieval functions: `recall_lessons`, `search_concepts`
- `tsvector` + GIN index strategy for sub-5 ms keyword recall
- Provenance gate trigger (blocks L3 canonical promotion by non-TL roles)
- Acceptance gate validation against ExpDesigner thresholds
- Competitive baseline harness (pgmnemo Variant 1 vs OpenBrain agent-memory schema)

**What this plan does NOT cover:**
- pgvector / HNSW embedding indexes (Phase 2)
- FastAPI write-path implementation (parallel track, BUILD-MEM-001)
- Apache AGE graph traversal (Phase 2)
- L4/L5 meta-cognitive or external-fact layers

**Budget envelope:** $25.00 with 10% phantom-DONE buffer (label `dag_budget:25.00`).

---

## 1. Extension Control File Structure

The extension ships as three files per the PGXS convention:

```
pgmnemo/
├── pgmnemo.control            # extension metadata
├── pgmnemo--1.0.sql           # full install DDL
├── pgmnemo--1.0--1.1.sql      # upgrade path (reserved for Phase 2)
└── Makefile                   # PGXS build rules
```

### 1.1 `pgmnemo.control`

```ini
# pgmnemo extension control file
default_version = '1.0'
comment         = 'Agent memory: lesson recall, concept search, provenance gating for LLM agent fleets'
module_pathname = ''           # pure SQL — no shared library
requires        = ''           # no dependencies beyond core PG 17
relocatable     = false        # uses fixed schema pgmnemo
schema          = pgmnemo
superuser       = false        # installable by database owner
trusted         = true         # can be installed by non-superuser in PG 13+
```

**Key design choice — `superuser = false`:** Avoids requiring DBA intervention on managed
PostgreSQL (Supabase, Neon, AlloyDB). The `trusted = true` flag (PG 13+) allows database
owners to `CREATE EXTENSION pgmnemo` without a superuser grant — critical for the commercial
distribution path identified in EXT-2.

### 1.2 Makefile (PGXS)

```makefile
EXTENSION   = pgmnemo
DATA        = pgmnemo--1.0.sql
PG_CONFIG  ?= pg_config

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
```

Install command (target machine): `make install` copies `pgmnemo.control` and `pgmnemo--1.0.sql`
to `$(pg_config --sharedir)/extension/`. Then `CREATE EXTENSION pgmnemo;` in any target database.

**5-minute install gate:** A fresh `make install && psql -c "CREATE EXTENSION pgmnemo;"` must
complete in under 5 minutes on a cold PostgreSQL 17 instance (acceptance gate AG-2).

---

## 2. Schema: Core Tables

All DDL lives in `pgmnemo--1.0.sql`. The schema is `pgmnemo` (fixed by `.control`).

### 2.1 `pgmnemo.agent_lesson` (L2 Episodic)

Stores per-run lessons learned: bug fixes, architectural decisions, anti-patterns observed.
Denormalized from the existing `lessons_*` active.md files — those become a write-through
cache of this table.

```sql
CREATE TABLE pgmnemo.agent_lesson (
  id              BIGSERIAL PRIMARY KEY,

  -- Origin provenance (mandatory — see §5)
  provenance_run_id   BIGINT       NOT NULL,   -- agent_run.id in host DB (no FK: cross-schema boundary ADR-003)
  provenance_role     TEXT         NOT NULL,   -- e.g. 'tech_lead', 'software_developer'
  provenance_trust    REAL         NOT NULL CHECK (provenance_trust BETWEEN 0.0 AND 1.0),

  -- Content
  lesson_text     TEXT         NOT NULL CHECK (length(lesson_text) <= 8000),
  lesson_summary  TEXT         CHECK (length(lesson_summary) <= 200),  -- Haiku-generated
  lesson_type     TEXT         NOT NULL DEFAULT 'general',  -- 'bug_fix'|'arch_decision'|'anti_pattern'|'general'

  -- Scope
  project_id      INT          NOT NULL,       -- projects.id (host DB, no FK per ADR-003)
  role_scope      TEXT,                        -- NULL = all roles; set to restrict recall to specific role
  tags            TEXT[]       DEFAULT '{}',   -- free-form labels, array for GIN indexing

  -- State machine (subset of mem_item_state, simplified for Variant 1)
  state           TEXT         NOT NULL DEFAULT 'active'
                               CHECK (state IN ('active', 'deprecated', 'archived')),

  -- Full-text search
  ts_body         TSVECTOR GENERATED ALWAYS AS (
                    to_tsvector('english', coalesce(lesson_text, ''))
                  ) STORED,

  -- Timestamps
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  deprecated_at   TIMESTAMPTZ,
  valid_until     TIMESTAMPTZ,    -- NULL = no expiry; set by retention policy (D3)

  -- Deduplication anchor (cosine dedup migrated from memory_curator.py)
  content_hash    TEXT GENERATED ALWAYS AS (
                    md5(lesson_text)
                  ) STORED
);

COMMENT ON TABLE pgmnemo.agent_lesson IS
  'L2 episodic memory: per-run agent lessons, searchable by tsvector + GIN. '
  'Write path: FastAPI /memory/items. Read path: pgmnemo.recall_lessons().';
```

### 2.2 `pgmnemo.memory_concept` (L3 Canonical)

TL-only promoted canonical facts about the project — architectural decisions, invariants,
security constraints. Promotion to this table requires the provenance gate trigger (§5).

```sql
CREATE TABLE pgmnemo.memory_concept (
  id              BIGSERIAL PRIMARY KEY,

  -- Provenance (mandatory + elevated trust)
  provenance_run_id   BIGINT   NOT NULL,
  provenance_role     TEXT     NOT NULL,
  provenance_trust    REAL     NOT NULL CHECK (provenance_trust >= 0.7),  -- L3 floor

  -- Content
  concept_text    TEXT         NOT NULL CHECK (length(concept_text) <= 4000),
  concept_summary TEXT         CHECK (length(concept_summary) <= 200),
  concept_type    TEXT         NOT NULL DEFAULT 'fact'
                               CHECK (concept_type IN ('fact','constraint','decision','invariant','pattern')),

  -- Scope
  project_id      INT          NOT NULL,
  domain_tags     TEXT[]       DEFAULT '{}',

  -- State (L3 only has canonical or deprecated — no draft/candidate cycle in Variant 1)
  state           TEXT         NOT NULL DEFAULT 'canonical'
                               CHECK (state IN ('canonical', 'deprecated', 'archived')),

  -- Full-text search
  ts_body         TSVECTOR GENERATED ALWAYS AS (
                    to_tsvector('english', coalesce(concept_text, ''))
                  ) STORED,

  -- Bitemporal
  valid_from      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  valid_until     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  superseded_at   TIMESTAMPTZ,
  superseded_by   BIGINT       REFERENCES pgmnemo.memory_concept(id)
);

COMMENT ON TABLE pgmnemo.memory_concept IS
  'L3 canonical memory: TL-only promoted project facts and decisions. '
  'Provenance gate trigger enforces role=tech_lead on INSERT/UPDATE.';
```

### 2.3 `pgmnemo.provenance_log` (Audit)

Append-only audit trail for every state-change event across both tables. Used by the
provenance gate trigger and by the eval harness to verify canonical purity (O-4).

```sql
CREATE TABLE pgmnemo.provenance_log (
  id              BIGSERIAL PRIMARY KEY,
  event_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),

  -- What changed
  table_name      TEXT         NOT NULL CHECK (table_name IN ('agent_lesson','memory_concept')),
  row_id          BIGINT       NOT NULL,
  event_type      TEXT         NOT NULL CHECK (event_type IN ('insert','promote','deprecate','archive','reject')),
  from_state      TEXT,        -- NULL for insert
  to_state        TEXT         NOT NULL,

  -- Who did it
  actor_role      TEXT         NOT NULL,
  actor_run_id    BIGINT,      -- NULL for manual TL operations
  actor_trust     REAL         NOT NULL CHECK (actor_trust BETWEEN 0.0 AND 1.0),

  -- Why (optional free-text)
  reason          TEXT         CHECK (length(reason) <= 500),

  -- Immutability guard
  CONSTRAINT provenance_log_no_update CHECK (true)  -- enforced by trigger below
);

COMMENT ON TABLE pgmnemo.provenance_log IS
  'Append-only audit trail for all pgmnemo state transitions. '
  'Rows are never updated or deleted — immutability enforced by trigger.';
```

---

## 3. PL/pgSQL Retrieval Functions

Both functions are designed for **zero external API calls on read** (acceptance gate AG-4):
they use only GIN-indexed tsvector or btree lookups. No embedding model is called.
Callers receive ranked rows; context assembly (token budget, dedup) is the caller's
responsibility.

### 3.1 `pgmnemo.recall_lessons`

Returns the top-N most relevant `agent_lesson` rows for a given query string and project,
ranked by `ts_rank_cd` (cover density weighting).

```sql
CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
  p_query       TEXT,
  p_project_id  INT,
  p_role        TEXT    DEFAULT NULL,    -- NULL = all roles; set to filter by role_scope
  p_limit       INT     DEFAULT 10,
  p_min_trust   REAL    DEFAULT 0.0,
  p_types       TEXT[]  DEFAULT NULL     -- NULL = all lesson_types
)
RETURNS TABLE (
  id              BIGINT,
  lesson_text     TEXT,
  lesson_summary  TEXT,
  lesson_type     TEXT,
  provenance_role TEXT,
  provenance_trust REAL,
  created_at      TIMESTAMPTZ,
  rank            REAL
)
LANGUAGE plpgsql
STABLE                   -- same inputs → same output within a transaction
SECURITY INVOKER         -- runs as calling role; RLS applies
AS $$
DECLARE
  v_tsquery TSQUERY;
BEGIN
  -- Validate inputs to prevent injection via to_tsquery
  IF p_query IS NULL OR trim(p_query) = '' THEN
    RETURN;
  END IF;

  -- Build tsquery using plainto_tsquery for safety (handles arbitrary user input)
  v_tsquery := plainto_tsquery('english', p_query);

  RETURN QUERY
  SELECT
    al.id,
    al.lesson_text,
    al.lesson_summary,
    al.lesson_type,
    al.provenance_role,
    al.provenance_trust,
    al.created_at,
    ts_rank_cd(al.ts_body, v_tsquery) AS rank
  FROM pgmnemo.agent_lesson al
  WHERE
    al.project_id        = p_project_id
    AND al.state         = 'active'
    AND al.ts_body       @@ v_tsquery
    AND al.provenance_trust >= p_min_trust
    AND (al.valid_until IS NULL OR al.valid_until > now())
    AND (p_role IS NULL OR al.role_scope IS NULL OR al.role_scope = p_role)
    AND (p_types IS NULL OR al.lesson_type = ANY(p_types))
  ORDER BY rank DESC, al.created_at DESC
  LIMIT LEAST(p_limit, 50);    -- hard cap at 50 to bound context injection
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons IS
  'Top-N tsvector recall over agent_lesson. No external API calls. '
  'Ranking: ts_rank_cd (cover density). Hard cap: 50 rows.';
```

### 3.2 `pgmnemo.search_concepts`

Returns canonical `memory_concept` rows matching a keyword query. L3 table only —
concepts are TL-promoted facts, so trust floor is higher than lessons.

```sql
CREATE OR REPLACE FUNCTION pgmnemo.search_concepts(
  p_query       TEXT,
  p_project_id  INT,
  p_types       TEXT[]  DEFAULT NULL,    -- NULL = all concept_types
  p_limit       INT     DEFAULT 10
)
RETURNS TABLE (
  id              BIGINT,
  concept_text    TEXT,
  concept_summary TEXT,
  concept_type    TEXT,
  domain_tags     TEXT[],
  provenance_role TEXT,
  valid_from      TIMESTAMPTZ,
  valid_until     TIMESTAMPTZ,
  rank            REAL
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tsquery TSQUERY;
BEGIN
  IF p_query IS NULL OR trim(p_query) = '' THEN
    RETURN;
  END IF;

  v_tsquery := plainto_tsquery('english', p_query);

  RETURN QUERY
  SELECT
    mc.id,
    mc.concept_text,
    mc.concept_summary,
    mc.concept_type,
    mc.domain_tags,
    mc.provenance_role,
    mc.valid_from,
    mc.valid_until,
    ts_rank_cd(mc.ts_body, v_tsquery) AS rank
  FROM pgmnemo.memory_concept mc
  WHERE
    mc.project_id   = p_project_id
    AND mc.state    = 'canonical'
    AND mc.ts_body  @@ v_tsquery
    AND (mc.valid_until IS NULL OR mc.valid_until > now())
    AND mc.superseded_at IS NULL
    AND (p_types IS NULL OR mc.concept_type = ANY(p_types))
  ORDER BY rank DESC, mc.valid_from DESC
  LIMIT LEAST(p_limit, 25);    -- L3 cap smaller — canonical rows are denser
END;
$$;

COMMENT ON FUNCTION pgmnemo.search_concepts IS
  'Keyword search over canonical L3 memory_concept rows. No external API calls. '
  'Only canonical, non-superseded, valid concepts returned.';
```

---

## 4. tsvector + GIN Index Strategy

### 4.1 Index definitions

```sql
-- agent_lesson: GIN on generated tsvector column
CREATE INDEX ix_agent_lesson_ts      ON pgmnemo.agent_lesson USING GIN (ts_body);
CREATE INDEX ix_agent_lesson_project ON pgmnemo.agent_lesson (project_id, state, created_at DESC);
CREATE INDEX ix_agent_lesson_role    ON pgmnemo.agent_lesson (role_scope) WHERE role_scope IS NOT NULL;
CREATE INDEX ix_agent_lesson_tags    ON pgmnemo.agent_lesson USING GIN (tags);

-- memory_concept: GIN on tsvector + btree on state + domain_tags GIN
CREATE INDEX ix_memory_concept_ts      ON pgmnemo.memory_concept USING GIN (ts_body);
CREATE INDEX ix_memory_concept_project ON pgmnemo.memory_concept (project_id, state, valid_from DESC);
CREATE INDEX ix_memory_concept_tags    ON pgmnemo.memory_concept USING GIN (domain_tags);

-- provenance_log: btree on (table_name, row_id) for audit queries
CREATE INDEX ix_provenance_log_row   ON pgmnemo.provenance_log (table_name, row_id, event_at DESC);
CREATE INDEX ix_provenance_log_actor ON pgmnemo.provenance_log (actor_role, event_at DESC);
```

### 4.2 Why GIN over GiST for tsvector

| Criterion | GIN | GiST |
|-----------|-----|------|
| **Query speed (lookup)** | Faster for exact/phrase match | Slower — must scan multiple levels |
| **Build time** | Slower (large indexes) | Faster |
| **Update cost** | Higher (deferred reindex possible) | Lower |
| **Index size** | Larger (~3× content) | Smaller |
| **pgmnemo fit** | Best: read-heavy, write-infrequent | |

For Agency-MEM-1 scale (target: ≤100K rows, ≤50 MB footprint — AG-3), GIN build time is
under 2 seconds on current dataset. GIN is correct.

**`GENERATED ALWAYS AS ... STORED`** strategy: the `ts_body` column is materialized at
write time, not computed at query time. This eliminates per-query `to_tsvector()` calls
and keeps the read path O(1) per GIN lookup.

### 4.3 Text configuration

Both `ts_body` columns use `'english'` configuration. For multi-language support
(Phase 2), the configuration can be parameterized via a `pgmnemo.config` table entry
without changing the function signatures.

### 4.4 Memory footprint estimate

| Table | Row size est. | Target rows | GIN overhead (~3×) | Total |
|-------|--------------|------------|---------------------|-------|
| `agent_lesson` | ~2 KB avg | 5 000 | ~30 MB | ~40 MB |
| `memory_concept` | ~1 KB avg | 1 000 | ~3 MB | ~6 MB |
| `provenance_log` | ~200 B | 20 000 | none | ~4 MB |
| **Total** | | | | **~50 MB** |

Target ≤50 MB at MVP scale satisfies AG-3.

---

## 5. Provenance Gate Trigger

The trigger enforces the K-4 constraint (ADR-001, PAPER §3.3): only `tech_lead` role
can insert or update rows in `memory_concept` (L3 canonical). It also writes every
state-changing event to `provenance_log` (immutable).

```sql
CREATE OR REPLACE FUNCTION pgmnemo._check_provenance_gate()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER    -- runs as extension owner, not caller role
AS $$
BEGIN
  -- Gate 1: only tech_lead may write to memory_concept
  IF TG_TABLE_NAME = 'memory_concept' THEN
    IF NEW.provenance_role <> 'tech_lead' THEN
      RAISE EXCEPTION
        'pgmnemo provenance gate: memory_concept INSERT/UPDATE requires provenance_role=''tech_lead''. '
        'Got: %. Run ID: %', NEW.provenance_role, NEW.provenance_run_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Gate 2: trust floor for L3
    IF NEW.provenance_trust < 0.7 THEN
      RAISE EXCEPTION
        'pgmnemo provenance gate: memory_concept requires provenance_trust >= 0.7. Got: %',
        NEW.provenance_trust
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- Append to provenance_log for all tables
  INSERT INTO pgmnemo.provenance_log (
    table_name, row_id, event_type, from_state, to_state,
    actor_role, actor_run_id, actor_trust, reason
  ) VALUES (
    TG_TABLE_NAME,
    NEW.id,
    TG_OP::text::pgmnemo.provenance_event_type_alias,  -- 'insert' or 'update'
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.state ELSE NULL END,
    NEW.state,
    NEW.provenance_role,
    NEW.provenance_run_id,
    NEW.provenance_trust,
    NULL   -- reason populated by explicit deprecate/promote functions
  );

  RETURN NEW;
END;
$$;

-- Attach to both tables: AFTER INSERT OR UPDATE, per row
CREATE TRIGGER trg_provenance_gate_lesson
  AFTER INSERT OR UPDATE ON pgmnemo.agent_lesson
  FOR EACH ROW EXECUTE FUNCTION pgmnemo._check_provenance_gate();

CREATE TRIGGER trg_provenance_gate_concept
  AFTER INSERT OR UPDATE ON pgmnemo.memory_concept
  FOR EACH ROW EXECUTE FUNCTION pgmnemo._check_provenance_gate();

-- Immutability trigger on provenance_log (no UPDATE or DELETE allowed)
CREATE OR REPLACE FUNCTION pgmnemo._forbid_provenance_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'pgmnemo: provenance_log is append-only; UPDATE/DELETE are forbidden'
    USING ERRCODE = 'insufficient_privilege';
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_provenance_immutable
  BEFORE UPDATE OR DELETE ON pgmnemo.provenance_log
  FOR EACH ROW EXECUTE FUNCTION pgmnemo._forbid_provenance_mutation();
```

**Why `SECURITY DEFINER`:** The provenance gate function must be able to INSERT into
`provenance_log` regardless of the calling role's table privileges. `SECURITY DEFINER`
runs the function as the extension owner; the trigger body never grants the caller
broader write access to other tables.

**Escape hatch:** A `provenance_role = 'tech_lead'` check is correct for autonomous
enforcement. For TL manual overrides (testing, corrections), the TL may set
`SET LOCAL pgmnemo.skip_gate = 'on'` within a transaction; the trigger reads
`current_setting('pgmnemo.skip_gate', true)` before enforcing. This is logged.

---

## 6. Acceptance Gates (per ExpDesigner spec)

Four binary gates must ALL pass before Phase 1 is considered complete and Phase 2 funds
are released.

| Gate | ID | Threshold | Measurement method | Week target |
|------|----|-----------|-------------------|-------------|
| Recall at 10 | AG-1 | `recall@10 >= 0.55` | Eval harness on BL-B fixture (100 rows, seed=42): count rows where correct lesson/concept in top-10 results | Week 4 |
| Install time | AG-2 | `<= 5 minutes` | `time make install && time psql -c "CREATE EXTENSION pgmnemo;"` on cold PG 17 Docker | Week 2 |
| Memory footprint | AG-3 | `<= 50 MB` | `SELECT pg_size_pretty(pg_total_relation_size('pgmnemo.agent_lesson') + pg_total_relation_size('pgmnemo.memory_concept') + pg_total_relation_size('pgmnemo.provenance_log'))` after loading 5 000 lesson + 1 000 concept fixture rows | Week 4 |
| Zero external API on read | AG-4 | No HTTP/TCP calls outside PG during any `recall_lessons` or `search_concepts` call | `strace -e trace=network -p $(pg_pid)` during 100 sequential read calls; 0 network events | Week 3 |

**AG-1 rationale:** 0.55 is below the BL-B anchor (0.62) because Variant 1 uses
tsvector-only recall (no embeddings). BL-B uses the full `bge-m3` + cosine path. The
0.55 gate verifies that pure keyword recall is not catastrophically worse than the
embedding baseline — the delta will be quantified in the competitive harness (§7).
Phase 2 will add vector recall to close the gap.

**Kill criterion:** If any gate fails after week 5 remediation, Phase 1 is BLOCKED and
the sprint is returned to design. Cost-at-BLOCK is logged as `dag_budget` consumed.

---

## 7. Competitive Baseline Harness (vs OpenBrain)

### 7.1 What OpenBrain provides

OpenBrain is the closest schema-level competitor to pgmnemo Variant 1 (referenced in
pgmnemo bootstrap SQL, task #135). It ships a `memory_items` table with `content TEXT`,
`metadata JSONB`, and optional `tsvector` column — no explicit provenance schema,
no canonical/episodic separation, no state machine.

### 7.2 Harness structure

The harness runs identical recall queries against both implementations on the same
frozen 100-row fixture (`spec/v2/memory-svc/fixtures/eval_baseline_100.json`).

```sql
-- Harness table: stores result sets for comparison
CREATE TABLE pgmnemo_eval.harness_run (
  id          SERIAL PRIMARY KEY,
  run_ts      TIMESTAMPTZ DEFAULT now(),
  system      TEXT NOT NULL CHECK (system IN ('pgmnemo_v1', 'openbrain', 'bl_b')),
  query_id    INT  NOT NULL,    -- 1..100 from fixture
  result_ids  INT[] NOT NULL,   -- top-10 returned row IDs
  latency_ms  REAL,
  recall_at_10 BOOL             -- computed after run: correct answer in result_ids?
);
```

Three comparison axes:

| Axis | pgmnemo V1 | OpenBrain | BL-B |
|------|-----------|-----------|------|
| Schema provenance | Mandatory (`provenance_role`, `provenance_trust`) | None | `agent_reflection` (partial) |
| Text recall mechanism | tsvector GIN + `plainto_tsquery` | Custom `ILIKE` or basic tsvector | Python cosine on `project_context_items` |
| State machine | 3-state (`active/deprecated/archived`) | Binary (`is_active BOOL`) | None |
| recall@10 target | ≥ 0.55 | Baseline (measured) | 0.62 (anchor) |
| Install ≤ 5 min | ✓ | Measured | N/A |

### 7.3 Harness execution plan

```bash
# Week 4, Day 1: load fixture into all three schemas
psql $DATABASE_URL -f harness/load_fixture_pgmnemo.sql
psql $DATABASE_URL -f harness/load_fixture_openbrain.sql

# Run recall benchmark (100 queries × 3 systems = 300 calls)
python3 harness/run_recall_benchmark.py \
  --fixture spec/v2/memory-svc/fixtures/eval_baseline_100.json \
  --systems pgmnemo_v1 openbrain bl_b \
  --out spec/reports/pgmnemo_PHASE1_EVAL.md
```

The benchmark script:
1. For each query in fixture: runs `pgmnemo.recall_lessons` + `search_concepts`
2. Checks whether the ground-truth row ID appears in the top-10 results
3. Records `latency_ms` via `EXPLAIN (ANALYZE, TIMING) ...`
4. Reports `recall@10`, `MRR`, p95 latency per system
5. Flags AG-1 pass/fail automatically

### 7.4 Expected outcome (design-time projection)

| Metric | pgmnemo V1 (projected) | OpenBrain (projected) | BL-B (measured) |
|--------|----------------------|-----------------------|-----------------|
| recall@10 | 0.55 – 0.65 | 0.40 – 0.50 | 0.62 |
| p95 latency | < 10 ms | < 15 ms | ~75 ms (FastAPI) |
| Install time | < 2 min | N/A | N/A |
| Memory footprint | < 50 MB | < 20 MB | ~115 MB (full DB) |

pgmnemo V1 is expected to underperform BL-B on recall@10 (no embeddings) but match or
exceed BL-B on latency and memory footprint. Phase 2 (embedding path) targets ≥ BL-B + 5 pp.

---

## 8. 6-Week Implementation Plan

### Week 1 (2026-04-29 – 2026-05-05): Extension Scaffold + Schema

**Deliverables:**
- `pgmnemo/pgmnemo.control` — control file per §1.1
- `pgmnemo/Makefile` — PGXS rules per §1.2
- `pgmnemo/pgmnemo--1.0.sql` — DDL for all three tables (§2.1–2.3)
- `pgmnemo/sql/00_schema.sql` — `CREATE SCHEMA pgmnemo`
- `spec/v2/pgmnemo/design/BUILD_MVP_EXT_PHASE1.md` — this document ✓

**Acceptance gate checkpoint:** None (scaffold only)
**Cost envelope:** ≤ $3.00

### Week 2 (2026-05-06 – 2026-05-12): GIN Indexes + Install Gate

**Deliverables:**
- All 9 index CREATE statements in `pgmnemo--1.0.sql` (§4.1)
- `make install` tested on Docker PG 17
- `CREATE EXTENSION pgmnemo;` completes < 5 min (AG-2 pass)
- `pgmnemo/harness/schema_openbrain.sql` — OpenBrain comparison schema

**Acceptance gate checkpoint:** AG-2 (install ≤ 5 min)
**Cost envelope:** ≤ $3.00

### Week 3 (2026-05-13 – 2026-05-19): Retrieval Functions + Provenance Gate

**Deliverables:**
- `recall_lessons` PL/pgSQL function (§3.1) — unit tested with `pgTAP`
- `search_concepts` PL/pgSQL function (§3.2) — unit tested with `pgTAP`
- `_check_provenance_gate` trigger (§5) — tested: non-TL insert raises exception
- `_forbid_provenance_mutation` trigger (§5) — tested: UPDATE on `provenance_log` raises
- AG-4 network isolation test: `strace` confirms 0 external calls during read

**Acceptance gate checkpoint:** AG-4 (zero external API on read)
**Cost envelope:** ≤ $5.00

### Week 4 (2026-05-20 – 2026-05-26): Eval Harness + Recall Gate

**Deliverables:**
- `harness/load_fixture_pgmnemo.sql` — loads 100-row eval fixture into pgmnemo tables
- `harness/load_fixture_openbrain.sql` — loads same fixture into OpenBrain schema
- `harness/run_recall_benchmark.py` — Python benchmark runner (§7.3)
- AG-3 footprint check: `pg_total_relation_size` after fixture load ≤ 50 MB
- AG-1 recall@10 measured: must hit ≥ 0.55 on BL-B fixture
- `spec/reports/pgmnemo_PHASE1_EVAL.md` — benchmark output

**Acceptance gate checkpoint:** AG-1 (recall@10 ≥ 0.55), AG-3 (footprint ≤ 50 MB)
**Cost envelope:** ≤ $6.00

### Week 5 (2026-05-27 – 2026-06-02): Remediation + Hardening

**Deliverables:**
- Fix any AG-1/AG-3/AG-4 failures from Week 4
- Add `pgmnemo.promote_concept()` helper function (TL-only L2→L3 promotion)
- Add `pgmnemo.deprecate_lesson()` helper (marks lesson state=deprecated, logs to provenance_log)
- `pgTAP` test suite: ≥ 30 tests covering all functions + triggers
- Update `pgmnemo--1.0.sql` with final DDL; tag `v1.0-rc1`

**Acceptance gate checkpoint:** All 4 gates re-verified on clean install
**Cost envelope:** ≤ $5.00

### Week 6 (2026-06-03 – 2026-06-09): Packaging + Documentation + Phase 1 Sign-off

**Deliverables:**
- `README.md` — install guide, quick-start SQL, AG thresholds
- `CHANGELOG.md` — v1.0 entry
- `pgmnemo--1.0--1.1.sql` — reserved upgrade script (placeholder DDL comment only)
- `spec/reports/pgmnemo_PHASE1_GATE_REPORT.md` — all 4 AG pass/fail evidence
- Founder sign-off on Phase 1 gates → Phase 2 (vector path) budget released

**Acceptance gate checkpoint:** All 4 gates documented with measured values
**Cost envelope:** ≤ $3.00

### Budget summary

| Week | Track | Cost ceiling |
|------|-------|-------------|
| 1 | Scaffold | $3.00 |
| 2 | Indexes + install | $3.00 |
| 3 | Functions + triggers | $5.00 |
| 4 | Eval harness | $6.00 |
| 5 | Remediation | $5.00 |
| 6 | Packaging | $3.00 |
| **Total Phase 1** | | **$25.00** |

---

## 9. Risk Register (Phase 1 specific)

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|-----------|
| R-P1-1 | AG-1 fails: tsvector recall < 0.55 on BL-B fixture (keyword mismatch on lesson vocabulary) | MEDIUM | HIGH | Reserve Week 5 for tuning: add synonym dictionary, adjust `to_tsvector` config, tune `ts_rank_cd` weight params |
| R-P1-2 | `GENERATED ALWAYS AS STORED` not supported on target PG version | LOW | HIGH | Minimum PG 12; Phase 1 targets PG 17 only. For PG 12–14 fallback: use explicit INSERT trigger to populate `ts_body` |
| R-P1-3 | Provenance gate trigger performance degrades batch INSERTs (lesson import) | MEDIUM | LOW | Trigger fires AFTER INSERT (not BEFORE); provenance_log insert is single row, O(1). Batch import benchmarked in Week 3 |
| R-P1-4 | OpenBrain schema changes before Week 4 benchmark | LOW | LOW | Pin OpenBrain schema at commit snapshot used in `harness/schema_openbrain.sql` |
| R-P1-5 | phantom-DONE on IMPLEMENT tasks (class-1/3) | HIGH (historical) | MEDIUM | All IMPLEMENT tasks must carry `requires_commit` label; SWDEV-260418-2 guard active |

---

## 10. References

- `ADR-001: Memory Service Substrate Selection` → `spec/v2/memory-svc/ADR_001_SUBSTRATE.md`
- `ADR-002: Memory Service Data Model` → `spec/v2/memory-svc/ADR_002_DATA_MODEL.md`
- `SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md` → EXT-3 HYBRID decision
- `RESEARCH_DESIGN-MEM-EXT-1_TECH_FEASIBILITY.md` → EXT-1 FEASIBLE_WITH_RISK
- `PAPER_DESIGN-MEM-001_v0.1.md` → Agency-MEM-1 pre-print; BL-B = 0.62 anchor
- `EVAL_METRICS.md` → primary metrics PM-01, EC-01, QM-01; statistical framework
- `EVAL_BASELINE_HARNESS.md` → 100-row fixture, BL-A/B/C definitions
- `spec/v2/memory-svc/fixtures/eval_baseline_100.json` → frozen eval fixture (seed=42)
- `SWDEV-260418-2` retro → phantom-impl guard; `requires_commit` label
- `spec/v2/pgmnemo/_migration_001_bootstrap.sql` → pgmnemo project bootstrap (project_id=18)
