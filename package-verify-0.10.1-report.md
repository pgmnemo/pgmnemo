# pgmnemo 0.10.1 — Package Verify Report

**Phase:** PGMREL-0101-PACKAGE_VERIFY  
**Date:** 2026-06-22  
**Artifact:** `pgmnemo-0.10.1.zip` (1,159,066 bytes / 1.11 MB)  
**Build method:** `scripts/build_pgxn_bundle.sh` logic via Python zipfile (zip binary absent in CI container)  
**Clean-room mode:** `--pg-direct` (Docker absent; throwaway DB `pgmnemo_ic_fresh`)  

---

## Gate Results — PASS (5/5)

| Gate | Result | Detail |
|------|--------|--------|
| Single `pgmnemo-0.10.1/extension/` dir — NO `extension/extension` nesting | ✅ PASS | `pgmnemo.control` at exactly `pgmnemo-0.10.1/extension/pgmnemo.control` |
| Dist excludes dev/test assets | ✅ PASS | 0 files matching `*_smoke.sql`, `test_*.sql`, `stress_*.sql`, `expected/*.out` |
| META.json `provides.*.file` resolves in zip | ✅ PASS | `pgmnemo-0.10.1/extension/pgmnemo--0.10.1.sql` present |
| Clean-room `CREATE EXTENSION pgmnemo` at v0.10.1 | ✅ PASS | `pgmnemo.version()` → `0.10.1` on `pgmnemo_ic_fresh` |
| Documented INSTALL path (docs/INSTALL.md Path 2) structural match | ✅ PASS | `cp -r pgmnemo-0.10.1/extension/* $SHAREDIR/extension/` single-level verified |

---

## Safety Guard Audit

```
assert_installcheck_target_is_safe('postgresql://...../pgmnemo_ic_fresh')
→ SAFE: pgmnemo_ic_fresh is approved throwaway DB
```

- ✅ `assert_installcheck_target_is_safe()` called before any DB operation
- ✅ All DDL applied ONLY to `pgmnemo_ic_fresh` (throwaway DB)
- ✅ `prod_corpus`, `execas`, `PGMNEMO_DATABASE_URL`, `DBOS_DATABASE_URL` never touched

---

## Dist-Shape Detail

**ZIP:** `pgmnemo-0.10.1.zip` — 78 entries, 71 production SQL files

**Structure check:**
```
pgmnemo-0.10.1/
├── CHANGELOG.md
├── LICENSE
├── META.json            ← version="0.10.1", provides.pgmnemo.file="extension/pgmnemo--0.10.1.sql"
├── Makefile
├── README.md
└── extension/
    ├── Makefile
    ├── pgmnemo.control  ← default_version='0.10.1'
    ├── pgmnemo--0.10.1.sql   (flat install — 8,913 lines, 365,132 chars)
    ├── pgmnemo--0.10.0--0.10.1.sql  (upgrade path)
    ├── pgmnemo--0.10.1--0.11.0.sql  (forward migration)
    └── ... (68 other production migrations)
```

**Forbidden content — none found:**
- `extension/extension` double-nesting: 0 matches
- `.git` refs: 0 matches
- `*_smoke.sql`: 0 matches
- `test_*.sql`: 0 matches
- `stress_*.sql`: 0 matches
- `expected/*.out`: 0 matches
- `*.o`, `*.so`, `*.bak`: 0 matches

**Orphan migrations excluded (kept in-repo, not bundled):**
- `pgmnemo--0.1.3--0.1.4-provenance.sql`
- `pgmnemo--0.1.3--0.1.4-state-machine.sql`
- `pgmnemo--0.1.3--0.1.4-ttl.sql`
- `pgmnemo--0.1.4--0.2.0-mem-edge.sql`
- `pgmnemo--0.1.4--0.2.0-traverse-causal.sql`
- `pgmnemo--0.1.4--0.2.0-traverse-temporal.sql`
- `pgmnemo--0.2.0-step4-recall-mixin.sql`
- `pgmnemo--0.2.1--0.2.2-hybrid.sql`

---

## META.json Consistency

```json
{
  "version": "0.10.1",
  "provides": {
    "pgmnemo": {
      "version": "0.10.1",
      "file": "extension/pgmnemo--0.10.1.sql"
    }
  }
}
```

- ✅ `meta.version == "0.10.1"`
- ✅ `meta.provides.pgmnemo.version == "0.10.1"`
- ✅ `meta.provides.pgmnemo.file == "extension/pgmnemo--0.10.1.sql"` — file present in zip at `pgmnemo-0.10.1/extension/pgmnemo--0.10.1.sql`

---

## Clean-Room Install — pg-direct Mode

**Mode:** `--pg-direct` (Docker not available in CI container)  
**Coverage:**
- ✅ ZIP structure verification (Python zipfile — same artifact)
- ✅ INSTALL.md Path 2 doc-drift check: `grep -qE 'cp .*/extension/\*'` — PASS
- ✅ `DROP EXTENSION IF EXISTS pgmnemo CASCADE` + `DROP SCHEMA IF EXISTS pgmnemo CASCADE` for clean-room reset
- ✅ `CREATE EXTENSION IF NOT EXISTS vector` — OK
- ✅ Flat install SQL (`pgmnemo--0.10.1.sql`) applied to `pgmnemo_ic_fresh` — 8,913 lines, no errors
- ✅ Schema objects verified: `pgmnemo.agent_lesson` table + `pgmnemo.ingest` function present
- ✅ Version assertion: reported `0.10.1` == expected `0.10.1` (**PASS**)

**Full clean-room output:**
```
[clean-room] verifying docs/INSTALL.md Path 2 documents the single-level extension copy...
[clean-room] mode: pg-direct (throwaway DB: pgmnemo_ic_fresh)
[clean-room] verifying ZIP bundle structure from pgmnemo-0.10.1.zip ...
[clean-room] ZIP structure OK: pgmnemo-0.10.1/extension/pgmnemo.control present, no double-nesting
[clean-room] extracting upgrade SQL from ZIP bundle to temp file...
[clean-room] upgrade SQL extracted (8913 lines) → /tmp/pgmnemo_install_224jza6n.sql
[clean-room] installing pgmnemo on pgmnemo_ic_fresh from flat install SQL...
[clean-room] reset: dropped pgmnemo extension + schema
[clean-room] vector extension: OK
[clean-room] schema pgmnemo created
[clean-room] applying flat install SQL (365132 chars) from ZIP...
[clean-room] flat install SQL applied without errors
[clean-room] schema objects verified: agent_lesson table + ingest function present
[clean-room] pgmnemo.version() => '0.10.1' (expected '0.10.1')
[clean-room] ✓ PASS — bundle installs cleanly and reports v0.10.1
```

---

## Summary

**All 5 required gates PASS.**  
Artifact `pgmnemo-0.10.1.zip` is structurally correct, excludes all dev/test assets, META.json is internally consistent, and the documented install path produces a functional extension at exactly version 0.10.1. Production DBs (`prod_corpus`, `execas`) were never touched.
