# PGXN Package Audit — pgmnemo v0.3.0
**Date:** 2026-05-10
**Auditor:** PGMNEMO-PREPUB-1-RESEARCH-B

---

## Checklist

| # | Check | Status | Action |
|---|-------|--------|--------|
| 1 | tags field | FIXED | Added: agents, rag, graph, pgvector |
| 2 | prereqs: pgvector | PASS | Already declared as `"vector": "0.7.0"` |
| 3 | provides.file vs version | FIXED | Updated from `pgmnemo--0.2.1.sql` to `pgmnemo--0.2.1--0.3.0.sql` |
| 4 | abstract length ≤72 chars | FIXED | Shortened from 84 → 67 chars |
| 5 | resources.repository | PASS | Present with url, web, type fields |
| 6 | zip validation | REBUILT | pgmnemo-0.3.0.zip regenerated |

---

## Detail

### 1. tags

**Before:** `["memory","agent","llm","vector","provenance","multi-tenant","hnsw","recall"]`

**After:** `["memory","agent","agents","llm","vector","pgvector","provenance","rag","graph","multi-tenant","hnsw","recall"]`

Added: `agents`, `rag`, `graph`, `pgvector` per task specification.

### 2. prereqs — pgvector

`prereqs.runtime.requires` already contained `"vector": "0.7.0"`. The PGXN extension name for pgvector is `vector`. No change required.

### 3. provides.file

**Before:** `"file": "extension/pgmnemo--0.2.1.sql"`

**After:** `"file": "extension/pgmnemo--0.2.1--0.3.0.sql"`

The provides version is 0.3.0 but the file pointed to the 0.2.1 base install. Updated to the 0.3.0 migration SQL which is the authoritative 0.3.0-specific file.

**Residual note:** For full PGXN spec compliance, a standalone `extension/pgmnemo--0.3.0.sql` base-install script should be created and `pgmnemo.control` `default_version` updated from `0.2.1` to `0.3.0`. This is a future packaging task.

### 4. abstract length

**Before (84 chars):** `Multi-agent memory substrate for PostgreSQL — provenance-gated, vector-hybrid recall`

**After (67 chars):** `Provenance-gated, vector-hybrid memory for LLM agents in PostgreSQL`

Applied to both top-level `abstract` and `provides.pgmnemo.abstract`.

### 5. resources.repository

Already present:
```json
"repository": {
  "url":  "https://github.com/pgmnemo/pgmnemo.git",
  "web":  "https://github.com/pgmnemo/pgmnemo",
  "type": "git"
}
```

No action required.

### 6. Zip validation

Rebuilt with:
```
zip -r pgmnemo-0.3.0.zip . --exclude .git/* --exclude *.pyc --exclude benchmarks/locomo/data/*
```

Zip contains valid META.json at root. PGXN validator requires META.json at the top level of the zip.

---

## Open issues (non-blocking for submission)

- `pgmnemo.control` `default_version` is `0.2.1`; should be `0.3.0` once a full base-install SQL is available.
- No `pgmnemo--0.3.0.sql` standalone install file exists; only upgrade path from 0.2.1 via `pgmnemo--0.2.1--0.3.0.sql`.
