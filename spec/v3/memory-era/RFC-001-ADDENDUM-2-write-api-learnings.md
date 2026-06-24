# RFC-001 ADDENDUM-2 — Write API Learnings: 7 Correctness Requirements

**Status:** Implemented in v0.12.0  
**Amends:** RFC-001-memory-organism.md §D2 (write contracts)  
**Effective:** 2026-06-24

---

## Background

During integration testing of the `remember_fact` write path (v0.12.0 development),
three bugs were surfaced by real-DB tests that mocks had hidden. This document
formalises seven correctness requirements that MUST be implemented INSIDE the
`remember_fact / remember_event / remember_relation` functions — not left to callers.

The principle: **caller stays thin**. All routing logic lives in the function.

---

## R1 — Explicit PII-aware default state routing (amends §D4)

`remember_fact` MUST route to `state` without caller involvement:

| Condition | State |
|---|---|
| Property is PII (`email / phone / address / telegram / full_name`) on a `person:*` key | `candidate` ALWAYS — even `system` source |
| `p_source_type = 'system'` and no PII | `validated` |
| `p_source_type = 'auto_captured'` | `candidate` |
| `p_source_type = 'agent_authored'` and `confidence ≥ 0.8` and no PII | `validated` |
| All other cases (low-conf agent, `imported`, NULL source) | `candidate` |

PII overrides ALL other conditions. This prevents a `system` source from accidentally
bypassing the PII candidate gate (ADR-61 D4 anti-poisoning invariant).

---

## R2 — Non-NULL artifact_hash synthesis

Entities have no `commit_sha`. The provenance gate in enforce mode rejects NULL
`artifact_hash`. `remember_fact` MUST synthesize:

```
artifact_hash = COALESCE(p_artifact_hash, 'fact-' || entity_key || ':' || property)
```

Synthesis happens **before** any gate inspection. A NULL `entity_key` → NULL slug →
NULL artifact_hash → gate rejection. Input guards must reject NULL `entity_key`.

Pattern for other function types:
- Events: `'event-' || entity_key || ':' || event_label`
- Relations: `'rel-' || from_key || ':' || relation_type || ':' || to_key`

---

## R3 — Identity/dedup keyed on `(lower(topic), project_id)` — absorb, not fork

The dedup identity is `(lower(topic), project_id)` using `SELECT FOR UPDATE` to
prevent write races. Topic encoding by content type:

- `fact`:     `lower(entity_key) || '/' || lower(property)`
- `event`:    `entity_key || ':event:' || event_label`
- `relation`: `from_key || ':' || relation_type || ':' || to_key`

**Merge path** (same value): update `confidence = GREATEST(existing, new)`;
re-classify state (can promote candidate→validated, never demote validated→candidate);
return **same id**.

**Supersede path** (different value): UPDATE prior row setting
`t_valid_to = now(), state = 'superseded'`; INSERT new row with
`version_n = prior.version_n + 1`; return **new id**.

Both paths are keyed on the **same identity** regardless of role. Two agents writing
to the same `(entity_key, property, project_id)` supersede each other — they do not
fork into separate rows.

---

## R4 — Drop-in upgrade from `ingest_entity`

Pre-v0.12.0 `ingest_entity` rows use `version_n = 0` as a sentinel. When
`remember_fact` finds a prior row with `version_n = 0`, it supersedes it with
`version_n = 1` on the first typed write. This makes `remember_fact` a drop-in
replacement: existing rows are absorbed into the bitemporal chain without data loss.

Migration: existing callers of `ingest_entity` can switch to `remember_fact` with the
same `entity_key + project_id`. No schema change required. See `docs/MIGRATION.md §C`.

---

## R5 — NULL embedding fail-open

A missing embedding must NOT block a write. `p_embedding = NULL` is valid and stored
as `embedding = NULL` in the row. Recall functions skip the vector component for
NULL-embedding rows (existing behaviour). Callers can backfill embeddings later.

The dimension check (1024) is enforced only when a non-NULL embedding is supplied.

---

## R6 — Tests target test DB; `guard_no_test_project` blocks prod

`guard_no_test_project(p_project_id INT)` raises when `project_id ≤ 100` (production
sentinel range). All integration tests MUST call this guard at setup. The function is
a no-op in allowed test databases.

Mock-based tests are PROHIBITED for the write path because mocks hid three real bugs:
- NULL artifact_hash accepted silently (R2)
- State routing skipping PII override on system source (R1)
- Dedup identity collision between fact and event content types (R3)

---

## R7 — `confidence` and `has_contact_pii` are first-class inputs

`p_confidence REAL DEFAULT 0.7` — influences state routing (R1), stored in row.
`p_has_contact_pii BOOLEAN DEFAULT NULL` — explicit override for PII detection:

```
_is_pii := COALESCE(p_has_contact_pii,
                    _has_contact_pii(property) AND entity_key LIKE 'person:%')
```

Caller can set `p_has_contact_pii = TRUE` to force candidate state for a property
not in the canonical PII set. Caller can set `FALSE` only to bypass auto-detection
when the caller has verified the property is not PII (use with care).

---

## Implementation status (v0.12.0)

| Requirement | Function | Status |
|---|---|---|
| R1 | `remember_fact` (state routing block) | ✅ |
| R2 | `remember_fact / remember_event / remember_relation` (artifact_hash) | ✅ |
| R3 | `remember_fact` (FOR UPDATE + merge/supersede) | ✅ |
| R4 | `remember_fact` (version_n=0 compat) | ✅ |
| R5 | `remember_fact` (NULL embedding accepted) | ✅ |
| R6 | `guard_no_test_project` + pg_regress test_remember_fact | ✅ |
| R7 | `remember_fact` (`p_confidence`, `p_has_contact_pii` inputs) | ✅ |
