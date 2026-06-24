# RFC-001 ADDENDUM — Typed Recall Coverage

**Status:** Active  
**Amends:** RFC-001-memory-organism.md §D1 / §D3 (recall contracts)  
**Effective:** v0.12.0

---

## Coverage requirement

Rows written via `remember_fact / remember_event / remember_relation` MUST be
retrievable by the existing recall functions (`recall_fast`, `recall_lessons`,
`recall_hybrid`) without caller-side changes.

## `verified_at` semantics and the recall visibility gate

`recall_fast` and `recall_lessons` filter on `is_active AND verified_at IS NOT NULL`.
This means:

| State | `verified_at` | Visible to default recall |
|---|---|---|
| `validated` | `NOW()` at write time | **Yes** |
| `candidate` | `NULL` | **No** (ghost — not visible until promoted) |

This is intentional: PII properties on `person:*` keys land in `candidate` and are
NOT surfaced to recall without explicit promotion by a trusted reviewer.

`SET pgmnemo.include_unverified = 'on'` overrides this for test/debug contexts. It
must NOT be set in production recall sessions.

## `content_type` filter

`recall_fast` and `recall_lessons` accept `p_content_types TEXT[] DEFAULT NULL`.
When set:

- `'{fact}'` — retrieves only typed-fact rows
- `'{event}'` — retrieves only event rows
- `'{fact','relation'}'` — retrieves facts and relations

NULL → all content types (backwards-compatible default). The filter is a pre-filter
on the candidate set, not a post-filter; it benefits from the
`ix_pgmnemo_content_type_active` index.

## Migration note for ingest_entity callers

Rows written via legacy `ingest_entity` have `content_type = NULL` (unset). These
rows are NOT matched by `p_content_types = '{fact}'`. After switching to
`remember_fact`, new writes set `content_type = 'fact'` and become filterable.

Bulk-update migration for existing rows:

```sql
UPDATE pgmnemo.agent_lesson
SET content_type = 'fact'
WHERE content_type IS NULL AND project_id = $1;
```

Run this once after switching to `remember_fact`. Rows already versioned as
`version_n = 0` will be superseded by the first `remember_fact` write, so migration
of recently active rows is optional.
