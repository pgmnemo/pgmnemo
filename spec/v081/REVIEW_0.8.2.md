---
date: 2026-06-05
agent: research_supervisor
task_id: PGMFIX-260604-REVIEW
branch: release/v0.8.2
commit: 011473c
status: APPROVE_FOR_SHIP
---

# pgmnemo 0.8.2 — WG Internal Review

**Verdict: APPROVE_FOR_SHIP**

Two non-blocking warns (WARN-1, WARN-2) and two informational notes are logged
below. No blockers found. All three required fixes are correctly implemented;
all release-prep artifacts are present and internally consistent.

---

## 1. Bug Context (from task brief)

**Adopter:** agentplatform.ru / RZD (real external production user).

**Scenario:** Lessons ingested without `commit_sha`/`artifact_hash` under
`gate_strict=warn` or `off` → `verified_at IS NULL` ("ghost rows") → default
recall returns empty silently → adopter tries `ALTER DATABASE SET
pgmnemo.include_unverified` but pool connections don't pick it up; AND the GUC
value `'true'` was silently rejected by `traverse_temporal_window`.

**Three diagnosed root causes addressed in 0.8.2:**

| Fix | File | Before 0.8.2 | After 0.8.2 |
|-----|------|--------------|-------------|
| F1 | `traverse_temporal_window` | `current_setting(...) = 'on'` (string-compare, rejects `'true'`/`'1'`) | `COALESCE(current_setting(...)::BOOLEAN, FALSE)` in `BEGIN/EXCEPTION` block |
| F2 | `recall_lessons`, `recall_hybrid` | Silent 0-row return when all lessons are ghosts | `RAISE NOTICE` with ghost count when `NOT FOUND` |
| F3 | `docs/SQL_REFERENCE.md` | No mention of connection-pool footgun for `ALTER DATABASE SET` | Explicit callout: affects new connections only; current session needs `SET` |

---

## 2. Verification Checklist

### 2.1 F1 — traverse_temporal_window include_unverified parsing

**Diagnosis confirmed:**
```sql
-- 0.8.1 (broken — string compare):
_include_unverified := COALESCE(
    (current_setting('pgmnemo.include_unverified', true) = 'on'),
    FALSE
);
-- rejects 'true', '1', 'yes' → silent exclusion when adopter uses SET pgmnemo.include_unverified='true'
```

**Fix in upgrade script (correct):**
```sql
BEGIN
    _include_unverified := COALESCE(
        current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
        FALSE
    );
EXCEPTION WHEN OTHERS THEN
    _include_unverified := FALSE;
END;
```

- ✅ Pattern matches all other recall functions (`recall_lessons`, `recall_hybrid`, `navigate_locate`, `navigate_expand`)
- ✅ `BEGIN/EXCEPTION` guard matches the pattern (catches malformed GUC values)
- ✅ `CREATE OR REPLACE` is safe — return type unchanged from 0.8.1
- ✅ Test T1 (`include_unverified='true'`) and T2 (`include_unverified='on'`) cover both parsers

### 2.2 F2 — Ghost guidance NOTICE

**Placement (correct):**

Both `recall_hybrid` and `recall_lessons` (vector-only path) place the ghost
check after `RETURN QUERY … LIMIT k;` using:

```plpgsql
IF NOT FOUND THEN
    SELECT COUNT(*)::INT INTO _ghost_count
    FROM pgmnemo.agent_lesson al
    WHERE al.is_active
      AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
      AND al.verified_at IS NULL
      AND (… role/project scope filters …);
    IF _ghost_count > 0 THEN
        RAISE NOTICE 'pgmnemo: % matching lesson(s) are unverified …', _ghost_count;
    END IF;
END IF;
```

- ✅ `FOUND` is set by `RETURN QUERY` in PL/pgSQL (documented: TRUE if ≥1 row returned)
- ✅ Single `COUNT(*)` — cheap; executes only on empty-result path
- ✅ Does NOT alter returned rows or ranking (diagnostic only)
- ✅ NOTICE message is accurate and actionable
- ✅ `t_valid_to = 'infinity'` filter matches active-row convention in pgmnemo schema

**Double-notice avoidance (correct):**

`recall_lessons` hybrid path:
```plpgsql
RETURN QUERY SELECT … FROM pgmnemo.recall_hybrid(…) h;
RETURN;  -- ← exits without running ghost check
```
`recall_hybrid` carries its own ghost check. Net: one NOTICE per call. ✅

**Role/project qualifier (correct):**

- `recall_lessons`: bare `role_filter` / `project_id_filter` parameter references ✅
- `recall_hybrid`: prefixed `recall_hybrid.role_filter` / `recall_hybrid.project_id_filter`
  (required by `#variable_conflict use_column`) ✅

**Test coverage (sufficient):**

| Test | Scenario | Expected |
|------|----------|----------|
| T4 | `recall_lessons`, ghost scope, include_unverified=off | COUNT=0, NOTICE fires |
| T5 | Prerequisite: ghost row exists in scope | ≥1 ghost confirmed |
| T6 | `recall_lessons`, ghost scope, include_unverified=on | COUNT≥1 (ghost returned) |
| T7 | `recall_hybrid`, ghost scope, include_unverified=off | COUNT=0, NOTICE fires |
| T8 | `recall_hybrid`, ghost scope, include_unverified=on | COUNT≥1 |

### 2.3 F3 — Docs: ALTER DATABASE connection-pool footgun

**Location:** `docs/SQL_REFERENCE.md` §2.2 "Disabling the provenance gate"

**Added content (correct):**
- New subsection documenting `pgmnemo.include_unverified` SET syntax (session, transaction, database, role)
- ⚠️ callout explicitly states: `ALTER DATABASE SET` / `ALTER ROLE SET` apply **only to new connections**
- Documents that existing MCP/pool connections must run `SET pgmnemo.include_unverified='on'` in-session
- Documents accepted values: `on`, `true`, `1`, `yes` (matching the ::BOOLEAN cast behavior after F1)

### 2.4 Release-Prep Completeness

| Artifact | Expected | Actual | Pass? |
|----------|----------|--------|-------|
| `extension/pgmnemo.control` `default_version` | `0.8.2` | `0.8.2` | ✅ |
| `META.json` top-level `version` | `0.8.2` | `0.8.2` | ✅ |
| `META.json` `provides.pgmnemo.version` | `0.8.2` | `0.8.2` | ✅ |
| `META.json` `provides.pgmnemo.file` | `extension/pgmnemo--0.8.2.sql` | `extension/pgmnemo--0.8.2.sql` | ✅ |
| `pgmnemo_mcp/pyproject.toml` version | `0.8.2` | `0.8.2` | ✅ |
| `pyproject.toml` (root) version | `0.8.2` | `0.8.2` | ✅ |
| `README.md` version badge | `0.8.2` | `0.8.2` | ✅ |
| `CHANGELOG.md` `[0.8.2]` entry | present | present (top of file, dated 2026-06-05) | ✅ |
| `extension/pgmnemo--0.8.1--0.8.2.sql` | present | present (673 lines) | ✅ |
| `extension/pgmnemo--0.8.2.sql` (flat) | present | present (5317 lines) | ✅ |
| Makefile DATA: `pgmnemo--0.8.1--0.8.2.sql` | present | present | ✅ |
| Makefile DATA: `pgmnemo--0.8.2.sql` | present | present | ✅ |
| Makefile REGRESS: `test_v082` | present | present | ✅ |
| `benchmarks/gate/v0.8.2.json` | present, carry-forward | present, `gate_type: analytical_carry_forward` | ✅ |
| 5 fixtures UPDATE TO `'0.8.2'` | `as_of_ts`, `bitemporality_smoke`, `rrf_sparse`, `temporal_boost_guc`, `stress_recall` | all updated | ✅ |
| `extension/sql/test_v082.sql` | T1-T8 | present (190 lines, T1-T8) | ✅ |

**Flat file sanity:**
- `pgmnemo--0.8.2.sql` starts with `\echo Use "CREATE EXTENSION pgmnemo"` guard (correct for flat install) ✅
- Ends with the F2 ghost-notice block from the upgrade script (content verified) ✅
- `pgmnemo.version()` reads from `pg_catalog.pg_extension.extversion` — returns `0.8.2` correctly after `CREATE/ALTER EXTENSION` ✅

---

## 3. Defects

### WARN-1 (Non-blocking): Ghost notice fires when include_unverified='on' + no semantic match

**Condition:** User has explicitly `SET pgmnemo.include_unverified = 'on'` (ghost lessons
ARE included in the search). Recall returns 0 rows because no lessons match the
query semantically. Ghost check runs, finds ghost lessons, and emits:

```
NOTICE: pgmnemo: N matching lesson(s) are unverified … and excluded by default.
```

The phrase "excluded by default" is factually incorrect — the lessons are NOT
excluded (include_unverified='on'). They simply didn't match the query.

**Impact:** Low. Requires (a) include_unverified already ON, AND (b) corpus with ghost
lessons that have no semantic similarity to the query. The primary adopter
scenario (RZD: default include_unverified=off, ghost lessons exist) is
unaffected and works correctly.

**Recommended fix (future patch):** Guard the `IF NOT FOUND` block:

```plpgsql
IF NOT FOUND AND NOT _include_unverified THEN   -- only warn when gate is active
    …ghost check…
END IF;
```

Deferred to 0.8.3 or can be applied as a hot-patch in this branch before tag.
The fix is trivial (one-line change per function).

### WARN-2 (Cosmetic): Flat file header comment says v0.8.1

`extension/pgmnemo--0.8.2.sql` opens with:
```
-- pgmnemo--0.8.1.sql
-- Flat install: pgmnemo v0.8.1
```

This is inherited from the `cat` of `pgmnemo--0.8.1.sql`. Functionally harmless —
`pgmnemo.version()` reads from catalog and returns `0.8.2` correctly. The
`\echo` guard correctly says `CREATE EXTENSION pgmnemo`. Recommend operator
patches the first two comment lines in the flat file before PGXN upload.

### INFO-1: DROP FUNCTION in upgrade script is unnecessary for this delta

`pgmnemo--0.8.1--0.8.2.sql` includes:
```sql
DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ);
```
before the new `CREATE OR REPLACE`. The 0.8.2 return type (17 cols) is identical
to 0.8.1 — `CREATE OR REPLACE` alone would suffice. The DROP is harmless and
safe (SRFs cannot have dependent views in standard PostgreSQL), but it is an
unnecessary DDL operation that could fail if a future adopter creates a dependent
object. Carried over from the 0.7.x upgrade chain pattern.

### INFO-2: PARALLEL SAFE + RAISE NOTICE behavior in parallel workers

`recall_hybrid` and `recall_lessons` retain `PARALLEL SAFE`. `RAISE NOTICE`
is permitted in PARALLEL SAFE functions; PostgreSQL delivers the messages to
the client (possibly buffered if running in a parallel worker). This is not a
correctness issue and matches existing behavior in the pre-0.8.2 codebase
(`recall_hybrid` already had RAISE NOTICE for the text-only footgun). No
action required.

---

## 4. Moat Preservation

The 0.8.2 changes are purely diagnostic and correctness fixes:
- No new API surface (no new functions, no new columns, no new GUCs)
- No scoring changes (WARN in gate file is analytical carry-forward)
- No per-doc LLM extraction introduced
- All fixes are query-engine-level (within PostgreSQL, no Python/MCP changes)
- Provenance gate is not relaxed: the NOTICE guides users to either provide
  provenance OR explicitly opt-in — it does not change the default behavior

---

## 5. Operator Ship Checklist

### Pre-tag (required)
- [ ] **pg_regress regen**: `make installcheck` on PostgreSQL 17 + pgvector.
  Expected-output files for `test_v082` do not yet exist — pg_regress will
  generate diffs on first run. Verify:
  - T1, T2 return `t`/`t` (ghost found with `'true'` and `'on'`)
  - T3 returns `t` (0 ghosts when include_unverified=off)
  - T4, T7 return `t` (0 rows from recall)
  - T5 returns `t` (ghost row confirmed to exist)
  - T6, T8 return `t` (ghost returned when include_unverified=on)
  - NOTICE lines in output for T4 and T7:
    ```
    NOTICE:  pgmnemo: 1 matching lesson(s) are unverified (ingested without
    commit_sha/artifact_hash) and excluded by default. SET
    pgmnemo.include_unverified = 'on' for this session, or pass provenance on ingest.
    ```
  - After verifying correct output, copy actual → expected:
    `cp results/test_v082.out expected/test_v082.out`
  - Re-run `make installcheck` — must show 0 failures

- [ ] **Upgrade path test**: On a DB with pgmnemo 0.8.1:
  ```sql
  ALTER EXTENSION pgmnemo UPDATE TO '0.8.2';
  SELECT default_version FROM pg_available_extension_versions
  WHERE name='pgmnemo' AND default_version='0.8.2';
  -- Verify traverse_temporal_window respects 'true':
  SET pgmnemo.include_unverified='true';
  SELECT COUNT(*) FROM pgmnemo.traverse_temporal_window(…);
  ```

- [ ] **Flat file header patch** (WARN-2): Update first two lines of
  `extension/pgmnemo--0.8.2.sql`:
  ```
  -- pgmnemo--0.8.2.sql
  -- Flat install: pgmnemo v0.8.2
  ```
  Then re-commit.

- [ ] **Optional WARN-1 fix**: Add `AND NOT _include_unverified` guard in
  both ghost-check blocks (recall_lessons + recall_hybrid) before tagging,
  or defer to 0.8.3. If deferred, add a GitHub issue.

- [ ] **CI green**: All GitHub Actions workflows pass.

### Tag & Publish
- [ ] `git tag -s v0.8.2 -m "pgmnemo 0.8.2 — F1/F2/F3 provenance fixes"`
- [ ] `git push origin release/v0.8.2 --tags`
- [ ] GitHub release: attach `pgmnemo-0.8.2.zip` (verify zip structure:
  `pgmnemo-0.8.2/extension/` — not double-nested, per v0.7.2 lesson)
- [ ] PGXN upload: `pgxn upload pgmnemo-0.8.2.zip`
- [ ] PyPI: `cd pgmnemo_mcp && python -m build && twine upload dist/*`
  (version 0.8.2 of pgmnemo-mcp)

### Telegram / Announce
- [ ] TG release note: highlight the RZD bug fix (ghost lessons, silent recall,
  GUC footgun), note NOTICE diagnostic, document `SET pgmnemo.include_unverified='true'`
  now works
- [ ] Update PGXN "stable" pointer if PGXN requires manual promotion

### Post-ship
- [ ] Reply to any open GitHub issues from agentplatform.ru/RZD indicating
  the fix is live in 0.8.2
- [ ] Monitor for follow-up reports on WARN-1 (false-positive notice); if
  observed in production, patch as 0.8.3

---

## 6. Summary

pgmnemo 0.8.2 correctly addresses all three root causes of the agentplatform.ru/RZD
production incident. F1 is a precise and minimal fix. F2 is correctly placed
(NOT FOUND only, single COUNT, no row/ranking impact), with clean double-notice
avoidance. F3 adds the documentation that should have accompanied the 0.8.1
FAQ. All 17 release-prep artifacts are present and internally consistent.

**APPROVE_FOR_SHIP** — pending pg_regress regen and optional WARN-1 guard fix.
