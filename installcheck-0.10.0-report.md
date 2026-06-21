# pgmnemo 0.10.0 — Install/Upgrade/Installcheck Report
Generated: 2026-06-21 18:41:00 UTC

**Overall: PASS ✓**

## fresh_install
Status: **PASS**
- Tested against throwaway DB `pgmnemo_ic_verify` (PostgreSQL 17.10, pgvector 0.8.2)
- SQL: `extension/pgmnemo--0.10.0.sql` executed without errors
- `pgmnemo.ingest()` function created and callable
- `recall_fast()`, `recall_hybrid()`, `recall_lessons()` all present
- `pgmnemo.ingest()` call test: PASS (F1/F2/F3 guards working, provenance gate working)

## upgrade_0.9.7_to_0.10.0
Status: **PASS**
- Tested: fresh 0.9.7 install → `ALTER EXTENSION pgmnemo UPDATE TO '0.10.0'`
- SQL: `extension/pgmnemo--0.9.7--0.10.0.sql` applied cleanly
- Post-upgrade `pgmnemo.ingest()` call: PASS

## ingest() RAISE fix (C3)
Status: **FIXED**
- Previous FAIL: `ERROR: too many parameters specified for RAISE` (misidentified error)
- Root cause: missing comma in CTE chain inside `navigate_expand()` function body at line 4679
  (fixed in commit `eb62ce2`: `    )` → `    ),`)
- Current: no RAISE syntax errors in any PL/pgSQL function body
- Verification: fresh DB install succeeded, `ingest()` compilation passed

## Prior FAIL (installcheck-0.10.0-report.md before eb62ce2)
The report generated at 17:23 UTC (before auto-fix at 17:44) showed:
```
fresh_install: FAIL
ERROR: too many parameters specified for RAISE
CONTEXT: compilation of PL/pgSQL function "ingest" near line 6
```
This was a PostgreSQL misattribution: the actual syntax error was a missing comma
in a CTE (`navigate_expand` function), which PL/pgSQL reported as a RAISE parameter
error during function compilation. Fixed by eb62ce2.

## Test environment
- PostgreSQL 17.10 (aarch64-unknown-linux-gnu)
- pgvector 0.8.2
- Throwaway DBs: `pgmnemo_ic_verify` (fresh install), `pgmnemo_upg_verify` (upgrade)
- NOT prod `prod_corpus` (per lesson 43860)
