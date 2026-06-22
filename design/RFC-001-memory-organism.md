# RFC-001: Typed Memory / Memory Organism

- **Status:** Draft
- **Target version:** 0.11.0
- **Created:** 2026-06-22
- **Authors:** pgmnemo maintainers
- **SPDX-License-Identifier:** Apache-2.0

---

## Summary

This RFC extends pgmnemo from a flat procedural-lesson store into a **typed memory organism**: a
unified, multi-representation store where every row carries an explicit **content type** that
describes the *kind of knowledge* it encodes. Five canonical types are introduced:
`procedure | entity | fact | event | relation`. New PL/pgSQL write wrappers
(`remember_fact`, `remember_event`, `remember_relation`) handle bitemporality, idempotency, and
versioning at the database layer. A new `p_content_types` filter on `recall_hybrid()` enables
pushdown type filtering before RRF re-ranking. A state-gate enforces that records about
identifiable individuals (PII) and records from unverified channels enter as `state='candidate'`
and are invisible to default recall until explicitly promoted, providing a principled
anti-memory-poisoning defence.

---

## Motivation

pgmnemo currently stores predominantly **procedural** knowledge — "how to do something" — in a
flat `agent_lesson` table. The schema already has the machinery to support richer
knowledge classification: `content_type`, `confidence`, the bitemporality columns
(`t_valid_from`/`t_valid_to`), `version_n`/`patch_count`, the `state` machine, and the
`mem_edge` graph. Most of these columns are under-utilised for knowledge-type discrimination.

Three concrete failure modes motivate this RFC:

**M1 — Retrieval degradation on mixed corpora.** When an agent recall corpus contains
procedures, entity definitions, factual properties, and event logs all undifferentiated, the
cosine-similarity and BM25 sub-plans compete against semantically incomparable rows. A query
asking "what is person:ada_lovelace's current affiliation?" scores poorly against procedural
lessons that happen to mention the same name. Content-type pushdown eliminates this class of
confusion before scoring.

**M2 — Fact staling without bitemporal discipline.** A fact stored as a plain lesson
(e.g. "project:widget status = in_progress") is never superseded — both old and new versions
accumulate. `recall_hybrid()` may surface the stale version if it scores higher. The schema has
`t_valid_from`/`t_valid_to` but no write path enforces temporal closure on update.

**M3 — Memory poisoning from untrusted input.** An agent that ingests content from an
unauthenticated external source without isolation can permanently alter its memory —
a known attack class against agent memory systems. PII rows about real people have additional
sensitivity. Without a staging gate, a single malicious ingest can write `state='validated'`
records visible to all subsequent recalls.

---

## Guide-level explanation

### The five content types

| `content_type` | Meaning | Typical topic slug | Mutable? |
|---|---|---|---|
| `procedure` | How to perform a task; a skill or workflow | `how-to:deploy-widget` | Yes — new version on revision |
| `entity`    | Identity record for a named thing (person, org, project, …) | `person:ada_lovelace`, `org:acme` | Yes — fact properties updated via `remember_fact` |
| `fact`      | A property–value assertion about an entity at a point in time | `person:ada_lovelace/affiliation` | Yes — old version closed, new version opened |
| `event`     | Something that happened at a specific time; immutable record | `org:acme/event/2024-merger` | No — append-only |
| `relation`  | A typed directed association between two entities | `(person:ada_lovelace, works_for, org:acme)` | Idempotent |

`item_kind` (note, skill_md, template, …) describes the **document format**. `content_type`
describes the **epistemic kind**. They are orthogonal and both live on `agent_lesson`.

### Entity identity

An entity is stored as a single row with `content_type = 'entity'` and a canonical topic slug
of the form `<entity_type>:<identifier>` — e.g. `person:ada_lovelace`, `org:acme`,
`project:widget`. The `metadata` JSONB carries `canonical_name`, `entity_type`, and optional
`aliases`. The existing HNSW+BM25 unique-content-hash mechanism and
`navigate_locate_dispatch(content_type_dispatch => 'entity')` already serve BM25-based entity
lookup without additional tables.

A separate `entity` table is deferred — see Rationale.

### Writing typed memory

```sql
-- Store or update a fact about an entity.
-- Closes the prior row for the same (entity_key, property) and opens a new version.
SELECT pgmnemo.remember_fact(
    p_role        => 'my-agent',
    p_entity_key  => 'person:ada_lovelace',
    p_property    => 'affiliation',
    p_value       => 'org:acme',
    p_confidence  => 0.9
);

-- Record an immutable event.
SELECT pgmnemo.remember_event(
    p_role        => 'my-agent',
    p_entity_key  => 'project:widget',
    p_event_label => 'milestone/v1-shipped',
    p_event_body  => 'Widget v1 shipped to production.',
    p_occurred_at => '2025-03-01T12:00:00Z'
);

-- Assert a directed relation between two entities.
SELECT pgmnemo.remember_relation(
    p_role          => 'my-agent',
    p_from_key      => 'person:ada_lovelace',
    p_to_key        => 'org:acme',
    p_relation_type => 'works_for',
    p_confidence    => 0.85
);
```

### Typed recall

```sql
-- Recall only facts and entities — exclude procedures and events.
SELECT * FROM pgmnemo.recall_hybrid(
    query_embedding => $1,
    query_text      => 'ada lovelace affiliation',
    p_content_types => ARRAY['entity', 'fact']
);

-- NULL (default) = full corpus, unchanged behaviour.
SELECT * FROM pgmnemo.recall_hybrid(
    query_embedding => $1,
    query_text      => 'widget deploy checklist'
);
```

### Privacy and anti-poisoning state gate

Records about **people** (`content_type = 'entity'` with `entity_type = 'person'`) or records
ingested from an **unverified channel** (e.g. agent-generated, externally scraped) automatically
enter as `state = 'candidate'`. Candidate rows are:

- **Invisible to default recall**: `recall_hybrid()` and `recall_lessons()` filter
  `state IN ('validated', 'canonical') AND confidence >= 0.3` by default.
- **Promotable** by two mechanisms:
  1. A second write from a *different* source corroborating the same `content_hash` (automatic
     promotion to `validated`).
  2. An explicit operator call: `pgmnemo.trust_record(lesson_id)`.

This provides a lightweight defence against **memory injection** attacks where an adversary
attempts to plant false or misleading memories via a channel an agent processes.

---

## Reference-level explanation

### 1. `content_type` typology (DDL change)

**Current state:** `content_type TEXT` (no CHECK constraint; v0.9.0 added for multimodal
doc-type tracking).

**Proposed change (v0.11.0):**

```sql
ALTER TABLE pgmnemo.agent_lesson
    ADD CONSTRAINT ck_agent_lesson_content_type
    CHECK (content_type IS NULL OR content_type IN (
        'procedure', 'entity', 'fact', 'event', 'relation'
    ));
```

Null remains permitted for backward compatibility — existing rows without a content type
continue to participate in all recall paths.

**Partial index for typed access paths:**

```sql
CREATE INDEX IF NOT EXISTS ix_agent_lesson_content_type_active
    ON pgmnemo.agent_lesson (content_type, t_valid_from DESC)
    WHERE is_active AND t_valid_to = 'infinity'::TIMESTAMPTZ
      AND content_type IS NOT NULL;
```

This index supports the pushdown filter in `recall_hybrid()` and the `navigate_locate_dispatch()`
entity path at no cost to NULL-type rows.

---

### 2. Entity identity conventions

Entity rows conform to the following invariants (enforced by `remember_fact`/`remember_relation`
and recommended for direct `ingest()` callers):

| Column | Value |
|---|---|
| `content_type` | `'entity'` |
| `topic` | `'<entity_type>:<identifier>'` — e.g. `person:ada_lovelace` |
| `metadata` | `{"canonical_name": "Ada Lovelace", "entity_type": "person", "aliases": [...]}` |
| `state` | `'candidate'` on first write; `'validated'` after corroboration |
| `t_valid_from` | Ingest timestamp |
| `t_valid_to` | `'infinity'` (active) |

The existing `content_hash`-based deduplication trigger ensures that re-ingesting the same entity
body closes the prior row and opens a new version — bitemporality at no extra cost.

---

### 3. Write API — function contracts

#### `pgmnemo.remember_fact()`

```
remember_fact(
    p_role         TEXT,
    p_entity_key   TEXT,              -- topic slug, e.g. 'person:ada_lovelace'
    p_property     TEXT,              -- property name, e.g. 'affiliation'
    p_value        TEXT,              -- value assertion
    p_confidence   REAL    DEFAULT 0.7,
    p_embedding    vector(1024) DEFAULT NULL,
    p_source       TEXT    DEFAULT NULL,  -- provenance tag
    p_commit_sha   TEXT    DEFAULT NULL,
    p_artifact_hash TEXT   DEFAULT NULL
) RETURNS BIGINT                      -- id of new/merged row
```

**Behaviour:**

1. **Merge** — if an active row exists with the same `(p_role, p_entity_key, p_property)` and
   identical `p_value`, update `confidence` to `GREATEST(existing, p_confidence)` and return the
   existing id (no version bump, no bitemporal close).
2. **Supersede** — if an active row exists with a *different* `p_value`, close it
   (`t_valid_to = now()`) and insert a new row with `version_n = prior.version_n + 1`.
3. **Insert** — if no active row exists, insert fresh with `version_n = 1`.

Steps 2 and 3 use `SELECT ... FOR UPDATE` on the prior row to prevent write races.

Topic of the inserted row: `p_entity_key || '/' || p_property` (e.g.
`person:ada_lovelace/affiliation`).

`content_type` is always `'fact'`.

State on insert: `'candidate'` when `p_source` is NULL or untrusted (no `p_commit_sha` and no
`p_artifact_hash`); otherwise `'validated'`.

#### `pgmnemo.remember_event()`

```
remember_event(
    p_role         TEXT,
    p_entity_key   TEXT,
    p_event_label  TEXT,              -- slug within entity scope
    p_event_body   TEXT,
    p_occurred_at  TIMESTAMPTZ DEFAULT now(),
    p_confidence   REAL        DEFAULT 0.8,
    p_embedding    vector(1024) DEFAULT NULL,
    p_commit_sha   TEXT        DEFAULT NULL,
    p_artifact_hash TEXT       DEFAULT NULL
) RETURNS BIGINT
```

**Behaviour:** Append-only — always inserts a new row. No dedup, no bitemporal close. Events are
immutable records of what happened. `content_type = 'event'`. Topic:
`p_entity_key || '/event/' || p_event_label`. `t_valid_from = p_occurred_at`.

#### `pgmnemo.remember_relation()`

```
remember_relation(
    p_role          TEXT,
    p_from_key      TEXT,             -- source entity slug
    p_to_key        TEXT,             -- target entity slug
    p_relation_type TEXT,             -- e.g. 'works_for', 'depends_on'
    p_confidence    REAL    DEFAULT 0.7,
    p_embedding     vector(1024) DEFAULT NULL,
    p_commit_sha    TEXT    DEFAULT NULL,
    p_artifact_hash TEXT    DEFAULT NULL
) RETURNS BIGINT
```

**Behaviour:** Idempotent on the triple `(p_from_key, p_to_key, p_relation_type)`. If an active
row exists, merges confidence (`GREATEST`). If not, inserts. Also calls `pgmnemo.add_edge()` to
write a typed `mem_edge` row with `edge_kind = 'entity'` and
`relation_type = p_relation_type`. `content_type = 'relation'`.

---

### 4. `recall_hybrid()` — typed filter extension

**New parameter:**

```sql
p_content_types  TEXT[]  DEFAULT NULL
```

Added as the last positional parameter; all existing callers using fewer or named parameters are
unaffected.

**Semantics:**

| Value | Behaviour |
|---|---|
| `NULL` (default) | No content-type filter — full corpus, identical to current behaviour |
| `ARRAY['fact', 'entity']` | Pushes `content_type = ANY(p_content_types)` into both the vector sub-plan and the BM25 sub-plan **before** RRF fusion |
| `'{}'::TEXT[]` (empty array) | Returns zero rows |

**[Mechanism]** The pushdown predicate hits the partial index
`ix_agent_lesson_content_type_active`. The planner can use a bitmap-AND of the HNSW/GIN index
with a bitmap scan of the partial btree — reducing the candidate pool before the O(k log k) RRF
merge step. For a corpus of 10 000 rows where 20 % are facts, this reduces the HNSW scan from
10 000 to ~2 000 rows *before* re-ranking.

**[Hypothesis]** For a type-tagged corpus (≥ 50 % non-procedure rows), typed-filter recall
should achieve ≥ 5 pp recall@10 lift at the same p_k, p < 0.05 (paired Wilcoxon). Falsifiable
benchmark spec: `spec/experiments/typed-recall-bench/`.

---

### 5. Privacy / anti-poisoning state gate

#### Default recall filter (v0.11.0)

`recall_hybrid()` and `recall_lessons()` add the predicate:

```sql
AND state IN ('validated', 'canonical')
AND confidence >= 0.3
```

to both sub-plans. Rows in `draft`, `candidate`, `conflicted`, `rejected`, `deprecated`,
`superseded`, `archived` states are excluded from default recall.

A GUC escape hatch allows explicit opt-in to candidate rows:

```sql
SET pgmnemo.include_candidate = 'on';
SELECT * FROM pgmnemo.recall_hybrid(...);
```

#### Auto-state assignment in write wrappers

| Condition | Assigned state |
|---|---|
| `p_commit_sha IS NOT NULL` OR `p_artifact_hash IS NOT NULL` | `'validated'` |
| `content_type = 'entity'` AND `metadata.entity_type = 'person'` AND no provenance | `'candidate'` |
| Any write without provenance fields | `'candidate'` |

#### Corroboration promotion

```
pgmnemo._maybe_promote_candidate(
    p_content_hash TEXT,
    p_incoming_source TEXT
) RETURNS VOID
```

Called internally on every insert. If an existing `candidate` row with the same `content_hash`
was written from a **different** `source_run_id` / `verifier_role`, the existing row is promoted
to `validated` and the incoming row is merged rather than duplicated.

#### Manual trust grant

```
pgmnemo.trust_record(p_lesson_id BIGINT) RETURNS TEXT  -- returns new state
```

Allows an operator to explicitly promote a `candidate` row to `validated` outside the
corroboration path. Blocked from promoting `rejected` or `archived` rows (state machine check).

#### Security rationale and prior work

[evidence] Memory injection attacks against agent systems are an active research area.
Zep (arXiv:2501.13956, "MemOS") and Mem0 (arXiv:2504.19413) both discuss adversarial
manipulation of persistent memory stores. The MINJA family of attacks (2024–2025) demonstrates
that an adversary who can inject a single record into an agent's memory can redirect
subsequent behaviour with high reliability. Poison-Once attacks (2024) show that a single
poisoned memory item can persist across many agent runs if no quarantine mechanism exists.

The candidate/validated state gate is a **structural** countermeasure: untrusted writes are
quarantined at the schema layer, not filtered post-hoc in application code. Corroboration
(multiple independent sources agreeing on the same `content_hash`) provides a Bayesian signal
before promotion. This does not eliminate poisoning from a compromised corroborating source, but
it raises the attack cost from O(1) writes to O(2) coordinated writes from distinct provenance.

---

### 6. Index additions summary (v0.11.0)

| Index | Type | Predicate | Purpose |
|---|---|---|---|
| `ix_agent_lesson_content_type_active` | BTREE | `is_active AND t_valid_to = 'infinity' AND content_type IS NOT NULL` | Typed recall pushdown |
| `ix_agent_lesson_state_conf` | BTREE on `(state, confidence)` | `is_active AND t_valid_to = 'infinity'` | State-gate recall pre-filter |

Existing indexes are unchanged.

---

### 7. Backward compatibility

| Caller | Impact |
|---|---|
| `ingest()` direct callers | Unaffected: signature unchanged, `content_type` stays NULL if not supplied |
| `recall_hybrid()` positional callers | `p_content_types` is a new **trailing** parameter with default NULL — no change in behaviour or result shape unless explicitly passed |
| `recall_lessons()` | Default recall filter (`state IN ('validated','canonical') AND confidence >= 0.3`) is a **breaking change** for callers who currently read `draft` or `candidate` rows. Migration: set `pgmnemo.include_candidate = 'on'` or promote rows before upgrading |
| `navigate_locate()` / `navigate_expand()` | No signature change; `content_type` filter is opt-in via `jsonb_filter` or the existing `navigate_locate_dispatch()` |
| `mem_edge` / `add_edge()` | Unaffected |
| State machine transitions | `candidate → validated` is already a legal transition (no DDL change required) |

The only breaking change is the default recall state filter. Existing deployments with all
lessons in `draft` or `candidate` state will see zero results from `recall_hybrid()` after
upgrade. Operators must run the provided migration helper before or immediately after upgrading:

```sql
-- Promote all currently-active draft/candidate lessons to validated in bulk.
-- Review and filter as appropriate before running.
UPDATE pgmnemo.agent_lesson
SET state = 'validated',
    state_changed_at = NOW()
WHERE state IN ('draft', 'candidate')
  AND is_active
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
```

---

## Drawbacks

**D1 — Schema coupling.** Adding a CHECK constraint on `content_type` is an ALTER TABLE that
acquires an ACCESS EXCLUSIVE lock. On large tables (> 1M rows) this requires a `NOT VALID`
strategy followed by a `VALIDATE CONSTRAINT` pass. Migration scripts must account for this.

**D2 — State-gate breaking change.** As noted above, deployments using
`state = 'draft'` as the default will break on upgrade. This is a deliberate trade-off:
the security benefit of the gate outweighs the migration inconvenience, but the migration
burden is real and must be clearly documented.

**D3 — Bitemporal complexity.** `remember_fact()` introduces a `FOR UPDATE` lock on the prior
row. Under high-frequency concurrent writes to the same `(entity_key, property)`, this creates
a serialisation point. Acceptable for typical agent-memory workloads (< 100 concurrent writes);
may require batching for bulk ingest pipelines.

**D4 — `remember_relation()` dual-write.** Writing both an `agent_lesson` row and a `mem_edge`
row in one function introduces a two-step write that cannot be atomic without wrapping in a
transaction. Both writes are inside the function body within a single transaction block, but
callers who issue `ROLLBACK` mid-function lose both writes — expected and consistent, but worth
documenting.

---

## Rationale and Alternatives

### Entity-as-row vs. separate `entity` table

**Chosen:** Entity-as-row (`content_type = 'entity'`, topic slug, metadata JSONB).

**Rationale:** A separate table adds a join to every entity-linked recall path, a FK maintenance
burden, and a second migration vector. The existing partial HNSW+BM25 indexes and the
`navigate_locate_dispatch(content_type_dispatch => 'entity')` path already serve entity lookup
efficiently. The `content_hash`-based dedup trigger provides identity stability.

**Threshold for revisiting:** > 1 000 distinct entities OR p99 entity lookup latency > 200 ms.
Above these thresholds a dedicated `entity` table with a FK from `agent_lesson` becomes worth
the join cost. This is tracked as a future RFC.

### `content_type` vs. `item_kind`

`item_kind` (note, skill_md, template, script, reference, config, spec) describes the
**document format** and rendering hint — it is presentational. `content_type` describes the
**epistemic category** — it governs access-path routing, recall filtering, and write-path
semantics. They are orthogonal. A `skill_md` document encoding a procedure has
`item_kind = 'skill_md'` and `content_type = 'procedure'`; a plain-text entity description has
`item_kind = 'note'` and `content_type = 'entity'`. Merging them into one column would require
a Cartesian product of values and break the existing `item_kind` CHECK constraint without
providing a clear semantic boundary.

### Lightweight temporal stamps vs. full NLP provenance pipeline

The bitemporal approach in `remember_fact()` (close-prior-on-supersede) uses only SQL-layer
timestamps and requires no NLP. An alternative is to extract temporal markers from text (e.g.
"as of Q1 2025") using a language model and write them as `t_valid_from`. This adds latency,
cost, and a failure mode (hallucinated timestamps). The SQL-layer approach is deterministic,
latency-free, and sufficient for the primary use case (agent-driven fact updates). NLP-extracted
timestamps can always be passed in as `p_occurred_at` to `remember_event()` — the two are not
mutually exclusive.

### Confidence threshold (0.3) for recall gate

0.3 is chosen as a conservative floor: a lesson that has failed 70 % of reinforcement events
has `confidence ≈ 0.3` at equilibrium under the default asymmetric update
(success_delta = 0.02, fail_delta = 0.12). Below 0.3, a lesson is more likely to be wrong
than right. The threshold is configurable via GUC `pgmnemo.recall_min_confidence` if operators
need a different floor.

---

## Prior art

Agent memory architectures increasingly distinguish knowledge types:

- **MemGPT / MemOS** (arXiv:2501.13956): layered memory with explicit promotion/demotion between
  in-context, archival, and working memory. Motivation for the state-gate aligns with MemOS's
  "memory curator" concept.
- **Mem0** (arXiv:2504.19413): structured memory management with entity extraction and
  deduplication. The entity-as-row pattern is informed by Mem0's entity-centric organisation,
  but implemented entirely in SQL rather than requiring a separate service.
- **LightRAG**: graph+vector hybrid retrieval. pgmnemo's `recall_hybrid()` already covers the
  hybrid recall dimension; `remember_relation()` + `mem_edge` covers the graph-construction
  dimension.
- **GraphRAG (Microsoft, 2024)**: community-based summarisation for large-scale graphs. Out of
  scope for v0.11.0; the `mem_edge` graph supports it as a future layer.
- **Temporal knowledge graphs** (TComplEx, TNTComplEx): bitemporality for fact validity is
  standard in the knowledge-graph literature. `t_valid_from`/`t_valid_to` follows this
  convention natively.

pgmnemo's distinctive position is **co-location in PostgreSQL**: the typology, the write
wrappers, the recall filter, and the state gate are all PL/pgSQL, callable over a standard
Postgres connection with no external service dependency. This is the architectural moat this RFC
extends, not abandons.

---

## Security

**Anti-poisoning (primary):** The state-gate described in §5 is the primary security control.
No additional cryptographic verification is added in v0.11.0.

**PII handling:** Person entities entering as `state = 'candidate'` provides a degree of
containment, but pgmnemo does not encrypt PII at rest or enforce column-level access control.
Operators handling sensitive personal data must apply PostgreSQL row-level security (RLS) and
encryption independently.

**Privilege escalation via `trust_record()`:** `trust_record()` requires no special role in
v0.11.0. Operators who need to restrict promotion to privileged roles should wrap the function
with a SECURITY DEFINER guard and grant execute selectively.

**Injection via `remember_fact()` property names:** No sanitisation is applied to
`p_property` or `p_value` beyond standard SQL parameterisation. SQL injection via these fields
is not possible (parameterised PL/pgSQL), but a caller with write access to the pgmnemo schema
can craft arbitrarily long property names. A length CHECK on topic (≤ 512 chars) should be
added — tracked as a follow-on issue.

---

## Unresolved questions

**U1 — Plural entity types.** Should `org`, `person`, `project`, `technology` be enforced as a
closed enum in `metadata.entity_type`, or remain free-text? Closed enum improves routing
precision; free-text improves extensibility. Decision deferred to implementor.

**U2 — Corroboration threshold.** Is a single corroborating source sufficient for promotion, or
should the threshold be configurable (e.g. 2-of-3 independent sources)? The current design uses
N = 2; this should be a GUC `pgmnemo.corroboration_n` defaulting to 2.

**U3 — `remember_relation()` and the lesson-vs-edge dual-write.** Should a relation create
*both* an `agent_lesson` row (for recall) *and* a `mem_edge` row (for graph traversal), or
only one? The current proposal writes both. An alternative is to write only the `mem_edge` and
expose relation recall via `navigate_expand()`. The dual-write approach preserves full
recall_hybrid coverage at the cost of redundancy.

**U4 — Migration path for existing rows.** The bulk-promote UPDATE provided in §7 is a blunt
instrument. A more targeted migration would classify existing rows by topic pattern (e.g.
topic matching `person:.*` → `content_type = 'entity'`) but this is heuristic and risks
misclassification. Should a classification helper function be provided?

**U5 — `p_content_types` and NULL rows.** When `p_content_types` is non-NULL, rows with
`content_type IS NULL` are excluded. Should there be an `'untyped'` sentinel in the array to
opt them back in? Current decision: callers must pass NULL for the parameter to include untyped
rows; mixing typed and untyped recall in one call is rare and can be achieved with two separate
calls followed by application-layer merge.

---

## Phased rollout

| Phase | Scope | Gate |
|---|---|---|
| **P0 — DDL only** | Add CHECK constraint on `content_type` (NOT VALID), add two new indexes, add `ck_agent_lesson_content_type` in NOT VALID state | No lock beyond `ALTER TABLE ADD CONSTRAINT NOT VALID` (ShareUpdateExclusiveLock). Validate in maintenance window. |
| **P1 — Write wrappers** | Ship `remember_fact()`, `remember_event()`, `remember_relation()`. Default provenance path: `state = 'candidate'` for no-provenance writes. No change to recall yet. | Verified by pg_regress suite; no existing callers affected. |
| **P2 — Typed recall** | Add `p_content_types` parameter to `recall_hybrid()`. Default NULL = unchanged behaviour. | Existing test suite passes without modification. Benchmark typed vs. untyped on ≥ 1 000-row corpus. |
| **P3 — State gate** | Enable `state IN ('validated', 'canonical') AND confidence >= 0.3` filter in `recall_hybrid()` and `recall_lessons()`. Ship `trust_record()` and `_maybe_promote_candidate()`. | **Breaking change.** Requires operator migration (bulk-promote or opt-in GUC). Ship migration script alongside. Announce with one minor version advance (v0.11.0). |
| **P4 — Validate constraint** | `VALIDATE CONSTRAINT ck_agent_lesson_content_type`. | Offline or low-traffic window. ShareUpdateExclusiveLock. |

Each phase ships as an independent `pgmnemo--0.10.1--0.11.0.sql` migration segment and is
independently revertible up to P3.
