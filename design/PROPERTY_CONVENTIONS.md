# Property Conventions — pgmnemo fact vocabulary

**Status:** ACTIVE (P1, Memory Era)
**Source:** ADR-61 §5.3 · §3 D2.1 · §3 D4
**Date:** 2026-06-22

---

## 1. Purpose

`pgmnemo.remember_fact(p_entity_key, p_property, p_value, …)` associates a typed
property–value pair with an entity hub.  The `p_property` argument is an **open
extensible key** — no database CHECK constraint enforces it.  This document is the
convention layer: standardised property names, value types, applicable entity prefixes,
and privacy classification.

Using conventions from this list ensures:

- Consistent `topic` column encoding across agents (`<slug>:<property>`)
- Correct privacy state-gate routing (§5 below)
- Interoperability with typed recall queries that filter by entity + property

---

## 2. Core property vocabulary

Properties are organised by domain.  The **Applies to** column lists slug-type prefixes
for which the property is meaningful; `any` means it may appear on any entity type.

### 2.1 Contact / identity

| Property | Value type | Applies to | Notes |
|----------|-----------|------------|-------|
| `email` | Text — lowercase RFC 5321 address | `person`, `org` | PII — privacy gate applies (§5) |
| `phone` | Text — E.164 format (`+15550001234`) | `person`, `org` | PII — privacy gate applies (§5) |
| `address` | Text — postal address, single line | `person`, `org`, `location` | PII — privacy gate applies (§5) |
| `telegram` | Text — handle without `@` | `person` | PII — privacy gate applies (§5) |
| `website` | Text — absolute URL | `org`, `project`, `product` | |
| `social_handle` | Text — `platform:handle` e.g. `github:ada` | `person`, `org` | |
| `timezone` | Text — IANA zone id e.g. `Europe/London` | `person`, `org` | |
| `language` | Text — BCP-47 tag e.g. `en`, `pt-BR` | `person`, `org` | |

### 2.2 Organisational / relational

| Property | Value type | Applies to | Notes |
|----------|-----------|------------|-------|
| `role` | Text — job title or functional role | `person` | e.g. `"Engineering Lead"` |
| `org` | Slug ref — `org:*` | `person` | Primary employer / affiliated organisation |
| `department` | Text | `person` | Organisational unit within `org` |
| `seniority` | Text — enum (`junior`, `mid`, `senior`, `lead`, `principal`, `director`, `vp`, `c_level`) | `person` | |
| `member_of` | Slug ref — `org:*` or `project:*` | `person`, `org` | Secondary membership; prefer `remember_relation(MEMBER_OF)` for graph traversal |
| `founded` | ISO date (`YYYY-MM-DD`) | `org` | |
| `size` | Text — enum (`solo`, `small`, `medium`, `large`, `enterprise`) | `org` | |
| `industry` | Text | `org` | Free-text or a taxonomy code |

### 2.3 Project / product lifecycle

| Property | Value type | Applies to | Notes |
|----------|-----------|------------|-------|
| `status` | Text — enum (`open`, `active`, `blocked`, `completed`, `cancelled`, `won`, `lost`) | `project`, `product`, `concept` | |
| `deadline` | ISO date (`YYYY-MM-DD`) | `project`, `concept` | Hard deadline or target date |
| `due_date` | ISO date (`YYYY-MM-DD`) | `project`, `concept` | Softer target; distinct from `deadline` |
| `priority` | Text — enum (`low`, `medium`, `high`, `critical`) | `project`, `product` | |
| `owner` | Slug ref — `person:*` | `project`, `product` | Accountable individual |
| `version` | Text — semver e.g. `1.2.3` | `product`, `project` | Current stable version |
| `license` | Text — SPDX id e.g. `MIT`, `Apache-2.0` | `product`, `project` | |
| `repository` | Text — URL | `project`, `product` | |

### 2.4 Knowledge / decision

| Property | Value type | Applies to | Notes |
|----------|-----------|------------|-------|
| `decision` | Text — one-sentence statement of the decision | `concept`, `project` | e.g. `"Use Variant A entity identity"` |
| `rationale` | Text — explanation | `concept`, `project` | Accompanies `decision` |
| `outcome` | Text — what actually happened | `concept`, `project` | Set after the fact |
| `confidence_source` | Text — URL or descriptor | `any` | Supporting evidence for a fact value |
| `description` | Text — free-form prose | `any` | Long-form description of the entity |
| `summary` | Text — ≤ 2 sentences | `any` | Short abstract |
| `tags` | Text — comma-separated lowercase labels | `any` | Lightweight categorisation |
| `alias` | Text — alternative name | `any` | Used for disambiguation; may be repeated |

### 2.5 Provenance / audit

| Property | Value type | Applies to | Notes |
|----------|-----------|------------|-------|
| `source_url` | Text — URL | `any` | Where the value was extracted from |
| `first_seen` | ISO datetime (`YYYY-MM-DDTHH:MM:SSZ`) | `any` | When the entity was first observed |
| `last_verified` | ISO datetime | `any` | When the value was last confirmed accurate |
| `verified_by` | Text — role identifier of verifier | `any` | Who performed verification |

---

## 3. Property naming rules

1. **Lower-case snake_case only** — no camelCase, no hyphens, no spaces.
2. **Singular noun** for point values (`email`, `role`, `status`).
3. **Repeating values** — if a property can legitimately have multiple values (e.g. several
   phone numbers), use distinct suffixes: `email_primary`, `email_work`, `email_personal`.
   Do not write multiple rows with identical `p_property`; `remember_fact` will supersede
   the previous value (see ADR-61 §3 D2.1 branch logic).
4. **Agent-defined extensions** — any agent may introduce a new property key not listed
   here.  New keys SHOULD be submitted as a PR to this file to remain discoverable.
   The naming rule above applies to extensions too.
5. **Namespace collisions** — if an extension key clashes with a future core key,
   the core key takes precedence and the extension key is deprecated.

---

## 4. Value encoding

| Type hint | Expected format | Notes |
|-----------|----------------|-------|
| Text | UTF-8 string | No length enforcement in DB; keep ≤ 2 000 chars for retrieval quality |
| ISO date | `YYYY-MM-DD` | No time component |
| ISO datetime | `YYYY-MM-DDTHH:MM:SSZ` | Always UTC, `Z` suffix required |
| E.164 phone | `+<country><number>` | e.g. `+15550001234` |
| Slug ref | `<type>:<canonical_id>` | Must satisfy SLUG_CONVENTION regex |
| Enum | One of the listed values | Stored as text; no DB CHECK |
| URL | Absolute URL | `https://` preferred |

Agents SHOULD normalise values to the specified format before calling `remember_fact`.
`canonical_slug()` (see SLUG_CONVENTION.md) handles slug-ref values automatically when
the caller passes through the typed write API.

---

## 5. Privacy classification and state gate

Properties are classified into two privacy tiers.  The `remember_fact` state gate
(ADR-61 §3 D2.1 / D4) enforces the initial `state` based on source type:

### 5.1 PII properties (restricted)

Properties in this class on `person:*` slugs are automatically downgraded to
`state='candidate'` when written via `source_type IN ('auto_captured','agent_authored')`:

- `email`
- `phone`
- `address`
- `telegram`
- `full_name` *(if stored as a fact rather than canonical_name)*

**Promotion to `'validated'`** requires one of:

1. The write uses `source_type='system'` (explicit, human-authorised channel), OR
2. A second distinct agent role writes the same value within 30 days (corroboration).

### 5.2 Non-PII properties (standard)

All other properties. Written with `state='validated'` when `p_confidence ≥ 0.8`, and
`state='candidate'` otherwise, regardless of `source_type`.

### 5.3 Canonical tier

Entity slugs that have been granted `state='canonical'` bypass the PII candidate gate
for all subsequent fact writes.  This is an explicit allow-list mechanism — use sparingly
for entities whose facts are frequently written by automated agents.

---

## 6. Recall behaviour

- Default `recall_hybrid` only surfaces facts with `state IN ('validated','canonical')`.
- Candidate-state facts are retrievable only when the caller passes
  `p_include_unvalidated=true` (power-tool; audit/review paths only).
- `p_content_types => ARRAY['fact']` in `recall_hybrid` restricts retrieval to facts,
  enabling property-focused queries without surfacing procedural lessons.

---

## 7. Examples

### Writing a contact fact

```sql
SELECT pgmnemo.remember_fact(
    p_role        => 'my_agent_role',
    p_project_id  => 1,
    p_entity_key  => 'person:ada_lovelace',
    p_property    => 'email',
    p_value       => 'ada@example.org',
    p_confidence  => 0.95,
    p_source_type => 'agent_authored'
);
-- Initial state: 'candidate' (PII property, not system-channel)
```

### Writing a project fact

```sql
SELECT pgmnemo.remember_fact(
    p_role        => 'my_agent_role',
    p_project_id  => 1,
    p_entity_key  => 'project:pgmnemo',
    p_property    => 'status',
    p_value       => 'active',
    p_confidence  => 1.0,
    p_source_type => 'system'
);
-- Initial state: 'validated' (system-channel, non-PII)
```

### Recalling facts by entity

```sql
SELECT * FROM pgmnemo.recall_hybrid(
    query_embedding   => <embedding>,
    query_text        => 'ada lovelace email contact',
    k                 => 5,
    role_filter       => NULL,
    project_id_filter => 1,
    p_content_types   => ARRAY['fact']
);
```

---

## 8. Relationship to other docs

| Document | Relationship |
|----------|-------------|
| `design/SLUG_CONVENTION.md` | Defines `p_entity_key` format used in this doc |
| `ADR-61 §5.3` | Primary source; this doc expands and operationalises it |
| `ADR-61 §3 D2` | `remember_fact` contract including state-gate logic |
| `ADR-61 §5.4` | `relation_type` whitelist for `remember_relation` |
