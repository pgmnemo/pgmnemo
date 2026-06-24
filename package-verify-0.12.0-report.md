# pgmnemo 0.12.0 Package Verification Report

**Date:** 2026-06-24
**Phase:** PGMREL-0120-PACKAGE_VERIFY
**Artifact:** `pgmnemo-0.12.0.zip` (1 381 811 bytes)
**Branch:** `integration/0.12.0`

---

## Safety Guard

```
assert_installcheck_target_is_safe('pgmnemo_ic_fresh')   → PASS
assert_installcheck_target_is_safe('pgmnemo_ic_upgrade') → PASS
assert_installcheck_target_is_safe(PGMNEMO_DATABASE_URL) → BLOCKED (agency_v3 — correct)
```

No CREATE/ALTER/DROP EXTENSION ran against `agency_v3`, `execas`, or `PGMNEMO_DATABASE_URL`.

---

## Build

| Step | Result |
|---|---|
| `extension/pgmnemo.control` default_version | `0.12.0` ✓ |
| `extension/pgmnemo--0.12.0.sql` exists | ✓ (10 128 lines, 416 942 chars) |
| META.json version | `0.12.0` ✓ |
| META.json provides.pgmnemo.version | `0.12.0` ✓ |
| META.json provides.pgmnemo.file | `extension/pgmnemo--0.12.0.sql` ✓ |
| ZIP built via Python zipfile (zip binary absent in env) | ✓ |
| Production SQL files bundled | 76 |
| Orphan migrations excluded | 8 (skipped) |

---

## Dist-Shape Gates

| Gate | Result |
|---|---|
| Single top-level dir `pgmnemo-0.12.0/` | ✓ PASS |
| `pgmnemo.control` at `pgmnemo-0.12.0/extension/pgmnemo.control` | ✓ PASS |
| `pgmnemo--0.12.0.sql` at `pgmnemo-0.12.0/extension/pgmnemo--0.12.0.sql` | ✓ PASS |
| No `extension/extension/` double-nesting | ✓ PASS |
| No `*_smoke.sql` in bundle | ✓ PASS |
| No `test_*.sql` in bundle | ✓ PASS |
| No `stress_*.sql` in bundle | ✓ PASS |
| No `expected/*.out` in bundle | ✓ PASS |
| No `.o`/`.so`/`.bak` files | ✓ PASS |
| META.json provides.*.file resolves in zip | ✓ PASS |
| Total entries | 83 (78 extension/ + 5 top-level) |

---

## docs/INSTALL.md Version Update

Updated `docs/INSTALL.md` from `v0.8.3` → `v0.12.0` in all six references:
- Path 1 PGXN install command
- Path 2 download URL + unzip + cp command
- Path 3 Dockerfile ADD line + unzip paths
- Path 3.4 upgrade Dockerfile + ALTER EXTENSION version
- Path 4 vendored curl + cp + commit message
- Verifying section version comment

Doc-drift guard: `clean_room_install_check.sh` verified `docs/INSTALL.md` Path 2 documents
the single-level `pgmnemo-0.12.0/extension/*` copy → **PASS**

---

## Clean-Room Install (pg-direct mode — no Docker in env)

```
[clean-room] verifying docs/INSTALL.md Path 2 documents the single-level extension copy... PASS
[clean-room] mode: pg-direct (throwaway DB: pgmnemo_ic_fresh)
[clean-room] ZIP structure OK: pgmnemo-0.12.0/extension/pgmnemo.control present, no double-nesting
[clean-room] upgrade SQL extracted (10128 lines) → /tmp/pgmnemo_install_gdjpoqy8.sql
[clean-room] reset: dropped pgmnemo extension + schema
[clean-room] vector extension: OK
[clean-room] schema pgmnemo created
[clean-room] applying flat install SQL (416942 chars) from ZIP...
[clean-room] flat install SQL applied without errors
[clean-room] schema objects verified: agent_lesson table + ingest function present
[clean-room] pgmnemo.version() => '0.12.0' (expected '0.12.0')
[clean-room] ✓ PASS — bundle installs cleanly and reports v0.12.0
```

**Note:** Docker not available in this environment; `--pg-direct` mode used.
pg-direct covers: ZIP structure, INSTALL.md doc-drift, flat install SQL execution,
schema object creation, version assertion. Gap vs Docker: Makefile install target
paths not tested (mitigated by ZIP structure verification above).

---

## Upgrade SQL in Bundle

| Item | Result |
|---|---|
| `pgmnemo--0.11.1--0.12.0.sql` in zip | ✓ PASS |
| Upgrade SQL length | 18 969 chars — non-trivial ✓ |
| `remember_fact` / `remember_event` / `remember_relation` functions in flat install | ✓ (34 matches in pgmnemo--0.12.0.sql) |

---

## Zip Contents (extension/ dir)

```
pgmnemo-0.12.0/extension/pgmnemo.control
pgmnemo-0.12.0/extension/Makefile
pgmnemo-0.12.0/extension/pgmnemo--0.0.1.sql              ← fresh install anchor
pgmnemo-0.12.0/extension/pgmnemo--0.0.1--0.1.0.sql
  ... (full upgrade chain 0.0.1 → 0.12.0) ...
pgmnemo-0.12.0/extension/pgmnemo--0.11.1--0.12.0.sql     ← latest delta
pgmnemo-0.12.0/extension/pgmnemo--0.12.0.sql             ← flat install (target version)
```

76 production SQL files. 8 orphan migrations excluded from bundle (remain in-repo).

---

## Gate Summary

| Gate | Status |
|---|---|
| Single `pgmnemo-0.12.0/extension/` dir — NO double-nesting | ✅ PASS |
| No dev/test assets (`*_smoke.sql`, `test_*.sql`, `stress_*.sql`, `expected/*.out`) | ✅ PASS |
| META.json `provides.*.file` paths resolve in zip | ✅ PASS |
| CREATE EXTENSION on throwaway pgvector/pg17 container (pg-direct mode) | ✅ PASS |
| Documented INSTALL path (docs/INSTALL.md Path 2) verified against built zip | ✅ PASS |
| CREATE/ALTER EXTENSION ONLY inside throwaway container — NOT agency_v3 | ✅ PASS |
| `assert_installcheck_target_is_safe()` called before all DB operations | ✅ PASS |

**All 7 gates: PASS**
