---
date: 2026-06-24
agent: research_supervisor
task_id: PGMREL-0120-RESEARCH
status: complete
branch: integration/0.12.0
---

# pgmnemo 0.12.0 — Research Brief
**Typed Write API: remember_fact / remember_event / remember_relation**

---

## Summary

pgmnemo 0.12.0 ships a structured write-path layer (`remember_fact`, `remember_event`,
`remember_relation`) encoding bitemporal supersession, PII-aware candidate routing, and
idempotency inside the database. The research finds: (a) three correctness gaps in the
salvaged `typed_write_api.sql` draft vs. the RFC-001 §D2 contract; (b) a new academic
competitor (Memanto, arXiv:2604.22085) that outperforms reported pgmnemo benchmarks —
requiring a positioning acknowledgement; (c) the memory-injection attack literature
(arXiv:2503.03704, arXiv:2604.02623) strongly supports the PII candidate-gate design;
(d) Zep/Graphiti is the nearest typed-write competitor but uses LLM-extracted triples,
not caller-authored SQL primitives.

---

## 1. Source inventory

| Source | Type | Evidence grade |
|---|---|---|
| `design/RFC-001-memory-organism.md` §D1/D2/D4/D5/D7 | Internal design doc | STRONG (authoritative) |
| `design/SLUG_CONVENTION.md` | Internal design doc | STRONG |
| `design/PROPERTY_CONVENTIONS.md` §5 | Internal design doc | STRONG |
| `extension/sql/typed_write_api.sql` | Draft SQL (design-intent only, per task spec) | MODERATE (diverges from RFC-001 §D2) |
| `design/RECONCILE_0.11.0.md` | Internal reconciliation report | STRONG |
| `CHANGELOG.md` [0.11.0], [0.11.1] | Release records | STRONG |
| `ROADMAP.md` (2026-06-20) | Public roadmap | STRONG |
| `spec/v0120/POSITIONING_REFRESH_PGMREL-0120.md` | Prior phase deliverable | STRONG |
| arXiv:2501.13956 (Zep MemOS paper) | Peer-reviewed | STRONG |
| arXiv:2604.22085 (Memanto) | Peer-reviewed (April 2026) | STRONG |
| arXiv:2503.03704 (MINJA attack) | Peer-reviewed | STRONG |
| arXiv:2604.02623 (Poison Once Exploit Forever) | Peer-reviewed | STRONG |
| arXiv:2601.05504 (Memory Poisoning Attack and Defense) | Peer-reviewed | STRONG |
| Mem0 entity-scoped memory docs (mem0.ai/platform/features/entity-scoped-memory) | Vendor docs | MODERATE |
| Graphiti GitHub (github.com/getzep/graphiti) | OSS code/docs | MODERATE |
| Memanto PyPI (pypi.org/project/memanto) | Package registry | MODERATE |

> ADDENDUM-2 reference files (`spec/v3/memory-era/RFC-001-ADDENDUM-2-write-api-learnings.md`,
> `spec/v3/memory-era/RFC-001-ADDENDUM-typed-recall-coverage.md`) are NOT present in the
> repository. The 7 correctness requirements from the task spec are treated as authoritative
> in-task specification; they should be committed to the repo before implementation begins.
> **Action: create these files as part of the implementation phase.**

---

## 2. Technical findings

### 2.1 Draft SQL vs. RFC-001 §D2 — three divergences

The salvaged `extension/sql/typed_write_api.sql` (per task spec: "design-intent ONLY") implements
`mem_write()` + a 10th-param overload of `ingest()`, NOT the `remember_fact / remember_event /
remember_relation` contracts defined in RFC-001 §D2. Three critical divergences:

| # | Divergence | RFC-001 §D2 requirement | Draft sql behaviour |
|---|---|---|---|
| **D-1** | Function shape | `remember_fact(p_role, p_entity_key, p_property, p_value, …)` | `mem_write(p_role, p_topic, p_lesson_text, p_content_type, …)` — no entity/property split |
| **D-2** | Bitemporal supersession | Close prior row (`t_valid_to=now()`) on value change; `FOR UPDATE` lock | Not implemented — plain `INSERT` via `ingest()` |
| **D-3** | PII-aware default state | PII properties on `person:*` → `state='candidate'` always | Not implemented — state logic absent |

**Conclusion:** The draft SQL is a pre-RFC scaffold. All three must be built from scratch per RFC-001 §D2 + 7 correctness reqs.

### 2.2 7 Correctness requirements (task ADDENDUM-2 spec) — status

| Req | Description | Status in current code |
|---|---|---|
| R1 | PII-aware state routing inside `remember_fact` | ❌ Not implemented |
| R2 | Non-NULL artifact_hash synthesis (`'fact-'‖entity_key‖':'‖property`) | ❌ Not implemented |
| R3 | Identity/dedup keyed on `(lower(canonical_key), project_id)` | ❌ Not implemented |
| R4 | Drop-in upgrade from `ingest_entity` (same key+project, version_n=0) | ❌ Not documented |
| R5 | Mandatory real-DB integration tests (not mocks) | ❌ Not written |
| R6 | Tests target `pgmnemo_bench` test DB; `guard_no_test_project` on prod | ❌ Not implemented |
| R7 | `confidence` + `has_contact_pii` as first-class inputs (thin caller) | ❌ Not implemented |

All 7 are green-field. None are carried over from existing code.

### 2.3 State machine breaking change (RFC-001 §7)

RFC-001 §7 identifies that `recall_hybrid()` / `recall_lessons()` defaulting to
`state IN ('validated','canonical') AND confidence >= 0.3` is a **breaking change**:
deployments with all lessons in `draft` or `candidate` will silently return 0 rows.
This is already in v0.11.0 for typed rows. For 0.12.0: any lesson written by
`remember_fact` with automatic `state='candidate'` routing will be invisible to default
recall until promoted. **Operators must run the bulk-promote helper or call
`trust_record(lesson_id)` before these lessons appear in retrieval.**

Source: `design/RFC-001-memory-organism.md §7 Backward compatibility`

### 2.4 Slug constraint gap

`PROPERTY_CONVENTIONS.md §5.1` lists the PII property set:
`{email, phone, address, telegram, full_name}`. These must be hard-coded in the
`has_contact_pii` detection logic inside `remember_fact` (req R1/R7). No SQL constraint
enforces them — the detection is a PL/pgSQL `IF p_property IN (...)` branch. Risk: if
a new PII property is added to the convention file but not to the function body, it
bypasses the candidate gate silently. **Mitigation: add a PROPERTY_CONVENTIONS.md
changelog entry requirement when new PII properties are defined.**

### 2.5 `remember_relation` dual-write atomicity

RFC-001 §D3 (Drawback D4): `remember_relation` writes both an `agent_lesson` row AND a
`mem_edge` row. Both are inside one transaction. If the function errors mid-write
(e.g. slug validation fails on `p_to_key` after the `agent_lesson` insert succeeds),
the transaction rolls back cleanly. No partial-write risk — but callers who explicitly
`BEGIN` + `ROLLBACK` lose both writes. Document explicitly in migration notes.

Source: `design/RFC-001-memory-organism.md §Drawbacks D4`

### 2.6 Release mechanics — missing artifacts

Current state on `integration/0.12.0`:

| Required artifact | Present? |
|---|---|
| `extension/pgmnemo--0.11.1--0.12.0.sql` | ❌ Missing |
| `extension/pgmnemo--0.12.0.sql` (flat) | ❌ Missing |
| `pgmnemo.control` `default_version=0.12.0` | ❌ Still 0.11.x |
| `Makefile` EXTVERSION + REGRESS for new tests | ❌ Not updated |
| `benchmarks/gate/v0.12.0.json` | ❌ Missing |
| `docs/release_notes/v0.12.0_telegram.md` | ❌ Missing |
| Both `pyproject.toml` files → 0.12.0 | ❌ Not bumped |
| README badge `version-0.12.0-` | ❌ Not updated |

All are standard release mechanics from 0.11.0/0.11.1 patterns. None are blockers that
require new research — all are implementation tasks.

---

## 3. Market / competitive findings

### 3.1 Typed write API landscape

| System | Typed write primitives | LLM cost per write | Notes |
|---|---|---|---|
| **pgmnemo 0.12.0** (proposed) | `remember_fact/event/relation` — caller-authored SQL | $0 | Rules inside DB, no extraction |
| **Zep/Graphiti** | Episodes → LLM-extracted entities + triplets | ~$0.36/1k writes | Automatic; caller writes "episode text" | Source: arXiv:2501.13956 |
| **Mem0** | Add-memory → LLM fact extraction + entity hub-spoke | ~$0.17/1k writes | Entities via spaCy, facts via LLM | Source: mem0.ai/platform/features/entity-scoped-memory |
| **Letta** | `core_memory_append()` — block-level, no typing | $0 incremental | No entity/fact/relation distinction |
| **Memanto** | 13 typed categories, LLM-classified on write | Unknown (cloud service) | Achieves SotA recall@10 (see §3.2) | Source: arXiv:2604.22085 |

**Key distinction:** pgmnemo's `remember_*` functions are caller-authored typed writes —
the agent decides the entity_key, property, value. Zep/Graphiti and Mem0 use LLM
extraction from unstructured episode text, which is higher-cost but lower friction.
pgmnemo's approach is correct for structured knowledge but requires the caller to already
know the entity identity and property name.

### 3.2 Memanto benchmark threat — SIGNIFICANT

arXiv:2604.22085 (April 2026, accepted at NeurIPS 2026 Workshop pending):

> Memanto achieves **89.8% LongMemEval** and **87.1% LoCoMo** accuracy with a single
> retrieval query.

pgmnemo's published figures: **LongMemEval-S recall@10 = 0.9604**, **LoCoMo session
recall@10 = 0.8409**.

Comparison requires caution — Memanto reports "accuracy" (QA match), pgmnemo reports
recall@10 (retrieval). These are not directly comparable metrics. However:

1. Memanto's LoCoMo 87.1% exceeds pgmnemo's 84.09% even if we treat recall@10 ≈ accuracy.
2. Memanto claims "state-of-the-art, surpassing all evaluated hybrid graph and vector-based systems."
3. If correct, pgmnemo's benchmark position is no longer "state-of-the-art."

**Recommended action (positioning, not implementation):**
- POSITIONING.md benchmark table must NOT claim SotA status for v0.12.0 without replication.
- Add Memanto row to competitor matrix with honest "not directly comparable — different metric" note.
- Evidence grade: STRONG for paper existence; MODERATE for claimed comparison (methodology
  comparison needed before accepting claim; pgmnemo's methodology is `docs/BENCHMARK_PROTOCOL.md`).

Source: [arXiv:2604.22085](https://arxiv.org/abs/2604.22085)

### 3.3 Memory injection attacks — candidate gate is well-motivated

Literature summary:

| Paper | Key finding | Relevance to pgmnemo |
|---|---|---|
| arXiv:2503.03704 (MINJA, 2025) | >95% injection rate via natural user interaction; delayed persistent behavioral manipulation | PII candidate gate raises attack cost: must write from 2 distinct provenance sources to promote |
| arXiv:2604.02623 (Poison Once Exploit Forever, 2026) | Single poisoned web-agent memory item persists across sessions without quarantine | Confirms: quarantine-first (`candidate`) is correct default for untrusted writes |
| arXiv:2601.05504 (Memory Poisoning Attack and Defense, 2025) | LLM-agent memory banks are susceptible; defense via filtering and state management | Candidate/validated gate is a structural (not post-hoc) countermeasure |
| arXiv:2605.23723 (MemAudit, 2026) | Post-hoc causal attribution for poisoned memory | Complements pgmnemo's audit trail; future RFC-002 territory |

**Verdict:** The RFC-001 §5 candidate/validated state gate is directly motivated by this
literature. The design is sound. The gate raises attack cost from O(1) writes to O(2)
coordinated writes from distinct provenance (RFC-001 §5 corroboration condition).

Source: [arXiv:2503.03704](https://arxiv.org/abs/2503.03704),
[arXiv:2604.02623](https://arxiv.org/html/2604.02623v1),
[arXiv:2601.05504](https://arxiv.org/html/2601.05504v2)

---

## 4. Decision questions answered

### DQ-1: Should 0.12.0 implement `remember_fact/event/relation` (RFC-001 §D2) or `mem_write()` (draft sql)?

**Answer: RFC-001 §D2 exclusively.**

The `typed_write_api.sql` draft is confirmed as design-intent only. It lacks bitemporal
supersession (D-2) and PII routing (D-3) — both are load-bearing correctness requirements
(R1, R2). `mem_write()` is a simple `ingest()` facade with no structural protections.
Delivering `mem_write()` as 0.12.0 would pass fewer correctness requirements and introduce
a naming confusion with the RFC-001 function family. The draft is a useful reference for
the `ingest()` parameter pattern but NOT the delivery shape.

Evidence: RFC-001 §D2 (STRONG); task spec (authoritative); draft sql analysis §2.1 above.

### DQ-2: Which PII properties trigger candidate routing in `remember_fact`?

**Answer:** The closed set from `PROPERTY_CONVENTIONS.md §5.1`:
`{email, phone, address, telegram, full_name}` on `person:*` slugs.

Implementation: `IF entity_key LIKE 'person:%' AND p_property IN ('email','phone','address','telegram','full_name')`.
Additionally: `source_type = 'auto_captured'` always routes to `candidate` regardless of
property (R1 routing table).

Evidence: `design/PROPERTY_CONVENTIONS.md §5` (STRONG)

### DQ-3: How should `ingest_entity` → `remember_fact` migration work?

**Answer:** Identity match on `(lower(topic), project_id)` where `content_type = 'entity'`.
Existing rows carry `version_n = 0` (sentinel for pre-migration rows). No data deletion
required; `remember_fact` on the same key produces `version_n = 1` and sets `t_valid_from`.
The `memory_ingest_log` table (added in v0.9.6) should record the migration batch.

Implementation task: create `docs/MIGRATION.md §C` (ingest_entity → remember_fact section).

Evidence: RFC-001 §D2 branch logic (STRONG); R4 task spec; CHANGELOG [0.9.6] (STRONG)

### DQ-4: Does Memanto invalidate pgmnemo's benchmark claims?

**Answer: No invalidation, but acknowledgement required.**

Memanto (arXiv:2604.22085) uses a different metric (QA accuracy) than pgmnemo (recall@10).
The systems are not on identical eval protocols. However, Memanto's LoCoMo performance
(87.1%) exceeds pgmnemo's (84.09%) even with metric difference as context. The honest
response is:

1. Do NOT update benchmark numbers in 0.12.0 (write-path release; no recall changes).
2. Add Memanto to POSITIONING.md competitor matrix with metric-comparison caveat.
3. Defer formal comparison to a post-0.12.0 bench sprint if needed for 0.13.0 positioning.

Evidence grade: STRONG (paper exists); MODERATE (metric comparison not apples-to-apples).

### DQ-5: Is the state-gate breaking change (recall returns 0 rows for candidate lessons) acceptable?

**Answer: Yes, with mandatory operator documentation.**

The breaking change (RFC-001 §7) is deliberately designed: security > migration convenience.
However, the upgrade guide must include the bulk-promote SQL helper. For 0.12.0 specifically:
any `remember_fact` writes for PII-bearing person-entity properties will be `candidate` by
default and invisible to recall until promoted. This is a SECURITY FEATURE, not a bug.

Documentation requirement: `CHANGELOG ## [0.12.0]` must include a migration note with the
`UPDATE ... SET state='validated'` helper and the `trust_record()` alternative.

Evidence: RFC-001 §7 (STRONG); PROPERTY_CONVENTIONS.md §5.1 (STRONG)

---

## 5. Open questions (for implementation phase)

| Question | Owner | Priority |
|---|---|---|
| Should `remember_fact` create the entity hub row if it doesn't exist? | Chief Architect | P0 — gates implementation |
| What happens when `p_entity_key` doesn't match slug regex? | Implementation | P0 — raise EXCEPTION or sanitize? |
| Should `remember_event` allow p_occurred_at in the past beyond a threshold? | Implementation | P1 |
| Should `confidence` feed the artifact_hash for provenance-gate bypass? | Implementation | P1 |
| Corroboration promotion timer (30-day rule in PROPERTY_CONVENTIONS §5.1): should this be a GUC? | Chief Architect | P2 |
