# Slug Convention — pgmnemo entity identifiers

**Status:** ACTIVE (P1, Memory Era)
**Source:** RFC-001 §3 D1 · §4.2 · §6 P0.3
**Date:** 2026-06-22

---

## 1. Purpose

Entity hubs in `pgmnemo.agent_lesson` are identified by a **canonical slug** — a short,
stable, human-readable key that survives renames, re-indexing, and cross-agent references.
The slug appears in:

- `metadata->>'canonical_name'` (enforced unique by `ix_entity_canonical_name_prj`)
- `topic` column (mirrors `canonical_name` for BM25 hit on exact phrase)
- `remember_fact` / `remember_relation` arguments `p_entity_key`, `p_from_key`, `p_to_key`
- Edge `metadata.from_key` / `metadata.to_key` in `pgmnemo.mem_edge`

---

## 2. Canonical form (regex)

```
^(person|org|project|product|location|concept):[a-z0-9_]+$
```

| Part | Rule |
|------|------|
| **type prefix** | One of the six closed-set values (§3) |
| `:` | Literal colon — the only permitted separator at the top level |
| **canonical_id** | Lower-case ASCII letters, digits, underscores only; no hyphens, no spaces, no Unicode |
| Length | 1–64 characters for the `canonical_id` part (total slug ≤ 72 chars) |

### 2.1 Valid examples

| Slug | Entity |
|------|--------|
| `person:ada_lovelace` | Historical figure (person) |
| `person:alan_turing` | Historical figure (person) |
| `org:acme` | Fictional company |
| `org:open_source_initiative` | Non-profit |
| `project:pgmnemo` | Software project |
| `product:mobile_app_v2` | Product release |
| `location:london_uk` | Geographic place |
| `concept:bitemporal_storage` | Abstract concept / domain term |

### 2.2 Invalid examples

| Value | Why invalid |
|-------|-------------|
| `person:Ada Lovelace` | Spaces not allowed |
| `person:ada-lovelace` | Hyphens not allowed (use underscore) |
| `Ada_Lovelace` | Missing type prefix |
| `human:ada_lovelace` | `human` is not a recognised type prefix |
| `person:` | Empty `canonical_id` |
| `PERSON:ada_lovelace` | Upper-case prefix not allowed |
| `person:adä_lovelace` | Non-ASCII character `ä` not allowed |

---

## 3. Type prefix vocabulary (closed set)

Extending this set requires an ADR amendment. Current values:

| Prefix | Applies to |
|--------|-----------|
| `person` | Individual human beings |
| `org` | Organisations, companies, teams, institutions |
| `project` | Discrete time-bounded initiatives, codebases, workstreams |
| `product` | Commercial or open-source products, service offerings |
| `location` | Geographic places — cities, regions, physical addresses |
| `concept` | Abstract ideas, domain terms, named methodologies, catch-all for entities that don't fit another prefix |

---

## 4. `canonical_slug()` — normalisation helper

```sql
-- Signature (PL/pgSQL, ships in P1)
CREATE OR REPLACE FUNCTION pgmnemo.canonical_slug(
    p_type  text,   -- must be one of the six prefixes
    p_label text    -- free-form label to normalise into canonical_id
) RETURNS text      -- e.g. 'person:ada_lovelace'
```

### Normalisation steps (applied in order)

1. **Strip accents / transliterate Unicode** → ASCII approximation
   (`é` → `e`, `ü` → `u`, `ñ` → `n`, etc.; implementation: `unaccent(p_label)` or equivalent)
2. **Lower-case** the result.
3. **Replace** any run of characters outside `[a-z0-9]` with a single underscore `_`.
4. **Strip** leading and trailing underscores.
5. **Truncate** to 64 characters (prefer truncating at the last `_` boundary).
6. **Prepend** `p_type || ':'`.
7. **Validate** result against `^(person|org|project|product|location|concept):[a-z0-9_]+$`.
   Raise `EXCEPTION` if `p_type` is not in the closed set or if the resulting id is empty.

### Examples

| Input `p_type` | Input `p_label` | Output slug |
|----------------|-----------------|-------------|
| `person` | `Ada Lovelace` | `person:ada_lovelace` |
| `person` | `Turing, Alan` | `person:turing_alan` |
| `org` | `Acme Corp.` | `org:acme_corp` |
| `org` | `Open Source Initiative (OSI)` | `org:open_source_initiative_osi` |
| `project` | `pgmnemo v2.0` | `project:pgmnemo_v2_0` |
| `location` | `São Paulo, BR` | `location:sao_paulo_br` |
| `concept` | `Bi-temporal Storage` | `concept:bi_temporal_storage` |

### Idempotency guarantee

`canonical_slug(type, canonical_slug(type, label))` MUST equal `canonical_slug(type, label)`.
Tests in `tests/sql/test_canonical_slug.sql` verify this invariant.

---

## 5. Usage in `remember_*` API

All three typed-write functions validate `p_entity_key` / `p_from_key` / `p_to_key` against
the canonical regex **before** any DB write. Callers may either:

- Pass a pre-validated slug directly, OR
- Pass the result of `pgmnemo.canonical_slug(type, label)` for automatic normalisation.

`remember_fact` additionally encodes the **property** into `topic` as:

```
<entity_slug>:<property>
```

e.g. `person:ada_lovelace:email`

`remember_event` encodes it as:

```
<entity_slug>:event:<event_type>
```

e.g. `person:ada_lovelace:event:contact`

---

## 6. Uniqueness contract

The UNIQUE index `ix_entity_canonical_name_prj` enforces:

```
UNIQUE (lower(metadata->>'canonical_name'), project_id)
WHERE content_type='entity' AND is_active
```

One canonical slug → at most one active entity hub per project. Slug collision means the
same real-world entity: callers MUST resolve to the existing hub rather than creating a
duplicate.

---

## 7. Slug stability policy

Once an entity hub is created with slug `S` and the row is `state IN ('validated','canonical')`:

- **Do not rename** `S` unilaterally. Create an alias fact (`concept:alias`) and redirect
  future writes to the new slug via a `SUPERSEDES` edge.
- **Merging two slugs**: close the weaker entity hub with `state='deprecated'`; add a
  `SUPERSEDES` edge from the canonical hub to the deprecated one; update callers.

---

## 8. Out of scope

- Sub-slug hierarchies (e.g. `project:pgmnemo:module:recall`) — not defined; use separate
  entities with `MEMBER_OF` relations.
- Numeric IDs or UUIDs as slugs — use `lesson_id` (PK) for row-level references; slugs
  are for semantic, human-meaningful identity only.
- Multi-project slug namespacing — slug uniqueness is scoped to `project_id` at the DB
  level; cross-project entity matching is a P2 concern.
